# AutoService v3 设计参照价值评估

> 2026-06-26 · gagameow
>
> 源仓库：`AutoService-new`（`D:\Work\h2os.cloud\AutoService-new`）
> 参照文档：
> - `docs/architecture/autoservice-overview.md`（2026-06-05 运行时实际状态）
> - `docs/architecture/2026-05-22-unified-storage-v3.md`（数据架构）
> - `docs/architecture/2026-05-07-three-customer-session-paths.md`（三条会话路径）
> - `docs/contracts/frontend-ws-schema.md`（WS 契约 v1.0 FROZEN）

---

## §1 背景

AutoService 经历了从 "三层 fork 架构" 到 **v3 两棵树架构**的演进。v3 的核心设计思想是：

1. **组件化**：storage 桥、Plugin 系统、WS 端点按角色分流、MCP 协议统一
2. **Admin session 驱动**：CR（Change Request）驱动的 sandbox → release 工作流，管理员所有操作自动收集到 active CR，二次确认后发布
3. **内容三层分离**：Soul（inline prompt）/ Skill（按需加载）/ KB（向量检索）

以下逐项评估对 ezagent 后续实施的参照价值。

---

## §2 组件化设计

### 2.1 storage/ 统一访问桥 — 🟡 中价值

**v3 设计**
```
autoservice/storage/  ← brokers both git repo + tenant data store
  (zero cc/git/runtime coupling)
```
- `resolve_unit(addr)` 通过 address 映射到 git 或 tenant data
- 与 cc_pool / git / LLM runtime 零耦合（CI lint `R-STORAGE-ISOLATION` 强制执行）
- snapshot 机制备份租户数据，canonical content hash 提供确定性 release 标识

**ezagent 现状**
- Kind/Snapshot 持久化层已存在（`kind_snapshots` 表 + `Ezagent.Kind.Snapshot`）
- 但缺乏统一的多租户数据访问抽象——目前各 domain 直接操作 Ecto

**参照建议**
- 可参照 `resolve_unit(addr)` 的 address-based 模型，在 ezagent 中建立统一的 `Ezagent.Storage` 层
- 特别有价值的是**零耦合约束**——storage 层不知道 cc/git/runtime 的存在
- 优先级：P2（非当前阻塞项）

### 2.2 Plugin 系统 — 🟢 已超越

**v3 设计**
```yaml
# plugins/<name>/plugin.yaml
mcp_tools: [...]
http_routes: [...]
```
- 声明式注册 + 自动发现

**ezagent 现状**
- Behavior + Kind + URI 三原语，`use Ezagent.Behavior` + `action` 宏
- Plugin 作为 OTP app，`agent_flavors/0` + `template_classes/0` + `after_boot/0`
- CapBAC 权限模型

**参照价值**：无需参照。ezagent 的 Plugin 模型更完善。

### 2.3 WS Schema 契约 — 🟡 高价值

**v3 设计**（`docs/contracts/frontend-ws-schema.md` v1.0 FROZEN）

三端点按角色分流：
```
/ws/customer   → viewer_role=CUSTOMER    → 隐式订阅自己的 conversation
/ws/operator   → viewer_role=OPERATOR    → 显式 subscribe 加入 conv + squad
/ws/admin      → viewer_role=ADMIN       → 隐式订阅全局事件流
```

核心机制：

| 机制 | 设计 |
|---|---|
| **Envelope** | `{v, type, id, ts, ref, payload}` 统一帧格式 |
| **版本协商** | `client_hello.protocol_version` ↔ `server_hello.accepted_versions` |
| **重连回放** | `last_seen {conv_seq, global_event_id}` → 补发 `message`/`event` 帧 → `replay_complete` |
| **Ring buffer** | per-subscription 独立窗口，防止单 hot conv 挤占其他订阅 |
| **关闭码** | `4408 idle`、`4018 SEQUENCE_GAP` 等语义化 close code |
| **Command 模式** | `operator_command` / `admin_command` → `command_response {ok, result?}` |
| **Admin 模型** | Admin 不直接 join conversation，通过 `actor_id` + Engine 权限矩阵 admin 列识别 |

**ezagent 现状**
- socialware socket 已有 `/socialware_socket`、`/socialware_chat_socket`
- 但缺少正式的 WS 协议契约文档和角色分流模型

**参照建议**
- **P0 优先级**：ezagent socialware socket 应参照此契约，建立正式的 WS 协议文档
- 特别有价值：`viewer_role` 注入、`subscribe`/`replay` 机制、per-subscription ring buffer、command/response 模式
- Admin 的"不直接 join conversation，通过权限矩阵识别"模型与 ezagent 的 CapBAC 理念一致

### 2.4 三条客户会话路径 — 🟡 中价值

**v3 设计**（`docs/architecture/2026-05-07-three-customer-session-paths.md`）

三条入口路径并排展示：接入→鉴权→租户解析→triage→池子→LLM→流式→持久化→推回，每步标注文件:行号。

**参照价值**：文档方法论本身有价值——ezagent 可参照此格式为 socialware 路径编写类似的 "完整链路文档"。

---

## §3 Admin session 驱动内容

### 3.1 CR 驱动的 sandbox → release 工作流 — 🔴 最大缺口

**v3 设计**
```
管理员编辑某 section / KB / skill
      ↓
PUT 端点写沙箱 + 自动 ensure_active_cr()
      ↓
当前 active draft CR 把这条改动加入
      ↓
（重复多次直到一组逻辑变更完成）
      ↓
admin 点 "发布" → 红色二次确认 → 服务端：
   - lint check
   - 计算 sandbox vs released 的实时 diff
   - promote 到新版本
   - flip _current 指针
   - recycle cc_pool
```

关键约束：
- 一个租户同时只有一个 active draft CR
- 已发布的项立即从 "追踪改动" 列表消失
- 大部分 publish 按钮都有红色二次确认弹窗
- 回滚走版本历史页选历史版本

**ezagent 现状**：无对应概念。配置直接生效，无预览→发布→回滚流程。

**参照价值**：若 ezagent 未来需要配置审批/发布/回滚能力，v3 的 CR 工作流是**唯一完整的参照实现**。

### 3.2 Soul / Skill / KB 三层内容分离 — 🟡 中价值

**v3 设计**

| 层 | 内容 | 加载方式 | 管理方 |
|---|---|---|---|
| **Soul** | inline prompt（~20KB） | cc 启动时全部塞入 system prompt | Framework + Platform + Industry + Tenant |
| **Skill** | 按需加载的 markdown 文件 | Read tool 按需读取，不进 system prompt | 同 Soul 四层 |
| **KB** | 向量检索的 chunk | MCP tool 查询 | tenant admin 上传 |

关键设计点：
- Soul 是 "角色人格"（inline），Skill 是 "知识手册"（on-demand），KB 是 "事实数据"（queryable）
- 四层覆盖：L0 Framework → L1 Platform → L2 Industry → L3 Tenant
- 旧概念合并：skill 文件 + flow_directive → Skill；priority.yaml → 退役

**ezagent 现状**
- SessionTemplate 有 config_schema + body
- Behavior 配置 per-instance
- 无 KB 检索层

**参照建议**
- P2 优先级：可参照三层分离思想，将 SessionTemplate 拆为 inline config + skill 附件 + 外部 KB 工具
- 四层覆盖模型（Framework→Platform→Industry→Tenant）可启发 Template 的继承/覆写机制

### 3.3 `{{slot}}` 模板系统 — 🟢 已覆盖

**v3 设计**
```yaml
# slot_values.yaml
identity:
  bot_full_name: "CINNOX AI Bot"
  host_site_descriptor: "CINNOX/M800"
```
- 模板含 `{{key}}` 占位符，管理员填槽值
- 缺失保留 raw `{{key}}` 作为信号
- 已去掉 priority.yaml、template_version、drift detection

**ezagent 现状**：`feat/agent-console` 分支的 config_schema 已覆盖此能力。无需参照。

### 3.4 Admin Portal V2 导航 — 🟢 已覆盖

**v3 设计**：左侧 rail 结构化导航，租户视角下 13 个功能入口。

**ezagent 现状**：World UI 已有类似结构（sessions / identities / workspaces / plugins / admin）。

---

## §4 部署 & 运营

### 4.1 Pipeline v2 — 🟢 不同模型

deepseek 安抚 + cc 主回复 + KB MCP 的三色流水线。ezagent 用 routing rules 实现消息分发，模型不同，无需参照。

### 4.2 cc_pool 多角色进程池 — 🟢 已覆盖

按 (tenant_id, role) sticky 复用的进程池。ezagent 的 Agent flavor + LocalRuntime 已覆盖。

### 4.3 熔断/降级 — 🟡 中价值

deepseek 连续失败 3 次 → 该会话永久 pin 回 v1 老路径。ezagent 缺少 circuit breaker 机制，可参照。

### 4.4 Two-tree split — 🟢 已覆盖

git repo + tenant data 分离。ezagent 的 workspace 隔离 + kind_snapshots 已实现类似效果。

---

## §5 总结：优先级排序

| 优先级 | v3 设计 | 参照内容 | ezagent 落点 |
|---|---|---|---|
| **P0** | WS Schema 契约 | 三端点角色模型、envelope 协议、subscribe/replay、command/response、close code 语义 | socialware socket 协议文档化 |
| **P1** | CR 驱动发布工作流 | sandbox→CR→lint→diff→promote→flip→recycle 完整链路 | 未来的配置审批/发布/回滚功能 |
| **P2** | Soul/Skill/KB 三层分离 | inline / on-demand / queryable 分层加载模型 | SessionTemplate 演进 |
| **P2** | storage/ 统一访问桥 | address-based 统一访问 + 零耦合约束 | 统一 Storage 抽象层 |
| **P2** | 三条会话路径文档 | 九步描点 + 文件:行号 的全链路文档格式 | 文档方法论 |
| **P3** | 熔断/降级 | 连续失败 N 次 → pin 回退路径 | Circuit breaker |
| **—** | Plugin 系统 | — | 已超越 |
| **—** | {{slot}} 模板 | — | 已覆盖 |
| **—** | Admin Portal V2 | — | 已覆盖 |
| **—** | Pipeline v2 / cc_pool / Two-tree | — | 模型不同或已覆盖 |

### 一句话结论

v3 设计对 ezagent 最有价值的不是代码实现，而是**两个文档**（WS Schema 契约、CR 工作流）和**一个思想**（Soul/Skill/KB 三层加载模型）。组件化层面 ezagent 已超越或等价，Admin session 驱动内容的 CR 工作流是 AutoService 最独特的设计，若 ezagent 未来需要配置审批发布，这是唯一参照。

---

*分析时间：2026-06-26 | 源仓库：AutoService-new (v3)*
