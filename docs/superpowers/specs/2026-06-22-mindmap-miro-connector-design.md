# 设计 · mindmap Miro 连接器 + 路线图重排（df-prd 增量 2-4）

> 分支 `feat/df-tech`（基于最新 main b6818123）。承接增量 1（`ezagent_plugin_mindmap` 已落地：节点树 Kind + Behavior + markmap，e2e 绿）。
> 本文据近期讨论定的方向重排路线图，并设计 Miro live 连接器。**杜绝想象**：承重机制对真实代码核实（飞书入站/external_mirror/session 持久化已读）。

## 0 · 路线图重排（消掉之前 1.5 vs 3 的冗余）

之前的 1.5（文件 CLI）和 3（Miro live）有真冗余：若走 Miro live，文件 export/import CLI 用不上。重排为：

| 增量 | 内容 | auth | 状态 |
|---|---|---|---|
| 1 | 节点树 Kind + Behavior + markmap render/parse（`:ephemeral`）| 无 | ✅ 已完成 |
| **2** | **durable 持久化**：Kind `:ephemeral` → `{:snapshot, :on_change}`，树跨重启存活。**所有后续共用的地基** | 无 | 本文，先做 |
| **3** | **节点富元数据 + 认领/状态**（owner/status/挂载产物）——df-prd"根源跟踪"核心，按 CapBAC per-node | 无 | 本文 |
| **4** | **Miro live 连接器**：external_mirror 出站 adapter → Miro REST + 入站 webhook → dispatch（含身份绑定 + CapBAC 复核）| **需 Miro auth** | 本文，到 auth 边界停下问用户 |

> markmap 文件导出（增量 1 已有）保留为**本地轻量 fallback**，不再投入文件 CLI（那是冗余）。
> `.xmind` 原生文件 backend：仅在确实离不开 XMind 时才做，当前不排期。

## 1 · 真相源决策（已定）

**ezagent 是真相源，Miro 是镜像/编辑面**。理由（已核实，与飞书同构）：
- 飞书消息也是两边都存：会话 Kind `persistence: {:snapshot, :on_change}`（`apps/ezagent_domain_session/lib/ezagent/entity/session.ex:96`）是本地权威，飞书是渠道镜像。ezagent 从不把外部当唯一真相。
- Miro（白板）装不下 df-prd 要的**可查询富节点数据**（owner/status/挂载产物/哪个 agent 在追踪，要能算周闭环数/认领率）。这些必须在 ezagent。
- 本地持久化可以**很轻**：只存节点树 + 富元数据，不复制 Miro 布局像素。

## 2 · 增量 2：durable 持久化

**改动**：`EzagentPluginMindmap.Mindmap` 的 `persistence/0` 从 `:ephemeral` 改为 `{:snapshot, :on_change}`（对齐 `Ezagent.Entity.Session` 先例）。节点树 state（单一 `:tree` key）即随每次 `{:set}` 落快照。

**验证（e2e，无 auth）**：spawn Mindmap → dispatch add_node ×N → 杀进程 → 经 SpawnRegistry 冷启动 respawn → dispatch get_tree → 树仍在。

**未决（开发中核实）**：snapshot 模式是否需要额外 schema/迁移（session 用的是 core 的通用 KindSnapshot，预计无需新表；开发时核实 `:ephemeral`→snapshot 是否仅改一行 + 验证 respawn）。

## 3 · 增量 3：节点富元数据 + 认领/状态

节点 map 扩展（仍在单一 `:tree` key 内）：
```
%{id => %{parent_id, title, order,
          owner: ezagent_user_uri | nil,     # 认领人
          status: :todo | :doing | :done,    # 状态
          artifacts: [%{tool, ref, url}]}}    # 挂载的外部产物引用(github PR/飞书文档…)
```
新动作：`claim_node(id)`（认领，写 owner=caller）/ `set_status(id, status)` / `attach_artifact(id, artifact)` / `unclaim_node(id)`。
**CapBAC per-node**：增量 1 的 admin cap 替换为细粒度——改某节点需"该节点 owner 或 admin"。`data_owner/1` 从 `:no_owner` 改为返回节点 owner（接 identity 域的 grant 收口）。

## 4 · 增量 4：Miro live 连接器

### 4.1 出站（ezagent → Miro）= external_mirror push adapter
- 新模块 `EzagentPluginMindmap.MiroAdapter`（`@behaviour Ezagent.ExternalMirror.Adapter`，push KIND）：`event_to_payload/1` **纯函数**，把节点树变化事件翻译成 Miro mind-map API 的 payload（建/改/删节点）。
- 配套 `MiroBinding`（GenServer）真正调 **Miro REST**（`POST/PATCH/DELETE .../mindmap_nodes`，experimental）。
- 经 plugin 的 `adapters/0` 声明 `{MiroAdapter, MiroBinding}`（对齐 feishu `{FeishuAdapter, FeishuChatBinding}`，`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:120`）。
- 节点 id 映射：维护 ezagent node_id ↔ Miro item_id 的双向表（一个 slice 或小表）。

### 4.2 入站（人在 Miro 改 → ezagent）= webhook → dispatch
- Miro board webhook → 一个入站端点（route in ezagent_web 或 plugin）→ 解析事件 → **身份映射**（见 4.3）→ **CapBAC 复核** → `Ezagent.Invocation.dispatch` 到 Mindmap Kind 的对应动作（add/move/rename/remove/...）。**P14：入站只走 dispatch。**
- 样板：feishu `inbound_dispatcher.ex`（`SenderResolver.resolve` → `{:ok, caller_uri, caps}` → dispatch，cap denied 则拒）。

### 4.3 身份绑定 + 权限模型（已讨论定）
- **Miro 用户 ↔ ezagent 身份绑定**（等价 feishu SenderResolver）：一个 bind 机制（mix 任务/小表）把 Miro user_id 映射到 ezagent user URI + caps。未绑定 → 扣住 + 提示绑定。
- **ezagent CapBAC 权威**：入站 Miro 改动按 ezagent 规则复核；**Miro 里允许但 ezagent 无权 → 拒绝 + 回滚**（向 Miro 回推正确状态，ezagent 仍是真相源）。
- 运营缓解：Miro 板成员范围对齐 ezagent 成员/认领，减少"改了被回滚"的摩擦。

### 4.4 防回声循环
ezagent→Miro 出站推送，会触发 Miro webhook 再回 ezagent。必须防 echo（对齐 echo Behavior 的 loop-safety）：用 **origin 标记 / 版本游标**——ezagent 自己推出去的变更带一个 sync token，webhook 回来时识别为"自己刚推的"则丢弃，只处理真正的人为改动。

### 4.5 Auth 需求（实现到此处会停下问用户）
要真连 Miro，需要用户提供（不绕过、不伪造）：
1. **Miro OAuth app**（client id + client secret）——或一个已签发的 **access token**。
2. **目标 board id**（在哪个板上建导图）。
3. **webhook 回调密钥**（验证入站 webhook 来自 Miro）。
存放：ezagent 凭证目录（`~/.ezagent/<home>/credentials/miro.yaml`，对齐 feishu 的 `feishu.yaml` 约定）或 env。**到这一步我会停下，列清楚要什么、放哪，等用户给。**

## 5 · 合规自查（每个增量都过）
- 纯 plugin（Miro 代码全在 `ezagent_plugin_mindmap/` 或单独 `ezagent_plugin_mindmap_miro/`），不碰 core/domain。
- 出站走 external_mirror adapter 契约；入站走 `Invocation.dispatch`（P14）。
- 全 PR gate：compile/`:ezagent_plugin_check`/arch.scan/check_invariants(+lifecycle)/doc.scan/format/test。
- 每增量 e2e 实测 + 证据文档（`docs/superpowers/evidence/`）+ 修改记录（`.artifacts/`）。

## 6 · 本次执行顺序
1. 写本 spec + 更新 plan（无 auth）。
2. 实现增量 2 durable 持久化 + e2e 验证（无 auth）。
3. 推进增量 4 到 **auth 边界**（adapter/binding 骨架 + 凭证读取位），**停下问用户要 Miro auth**。
