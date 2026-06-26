# AutoService v3 参照评估 + ezagent 分步实现 roadmap

> 来源：#1031（gaga 的 AutoService v3 设计参照评估）+ #1024（AutoService 对标审计的 6 项 parity gap）。
> 本文对 ezagent **当前功能做了代码级扫描**，纠正了若干"无对应概念"的误判，并按依赖+价值给出分步实现顺序。
> 决策口径：lead（林懿伦）2026-06-26。

## 0. 一句话结论

v3 在**架构上已被 ezagent 超越**（Behavior+Kind+URI+CapBAC+OTP-app 插件契约 > v3 的声明式 plugin.yaml）。真正值得参照的是**少数机制**，而 6 项 parity gap 里**只有 2 项是真空白**（KB 向量检索、计费看板）；其余要么已覆盖（附件、Soul/Skill 分层），要么是在**已有原语上做扩展**（CR 治理、WS 契约），被原评估**低估了完成度**。

## 1. 当前覆盖真相（代码级扫描）

| 候选（v3 / #1024 gap） | 判定 | 证据 / 缺什么 |
|---|---|---|
| **WS Schema 契约**（3 角色端点 + subscribe/replay/envelope/版本/close 码） | **部分** | 已有两个角色路由 socket（`customer_socket.ex` + `chat_feed_socket.ex`），token 鉴权、投影隔离、**游标 replay**（idempotent by `committed_seq`）——机制 ≥ v3。缺：**冻结契约**（`{v,type,id,ts,ref,payload}` envelope、`client_hello/server_hello` 版本握手、语义 close 码、第三个 admin 全局事件端点）。是契约+握手+admin 流，不是机制。 |
| **CR 治理**（Dream→提案→CR→publish/rollback；sandbox preview/release） | **部分，比评估强得多** | 已有硬核：`config_store.ex` 不可变 `ConfigObject`（append-only）+ `ConfigPointer`（可变层）、`write_and_point/1` 原子、**rollback = repoint 到保留的旧对象**（正是 v3 模型）、`previous_config_id` + `source_turn_id` 幂等。`config_evolve.ex` agent 自演化（对象→指针→延迟 sandbox 写→crash 自愈）。缺**上层工作流**：多 delta **草稿聚合**、**review 门**（lint + sandbox-vs-released diff + 二次确认）、**publish 仪式**（promote+翻指针+回收）、Dream 自动提案源。 |
| **Soul/Skill 分层** | **已覆盖** | `role.ex`（#54）已把内容（prompt/persona=Soul、`skills`=Skill、plugins、behaviors、caps）与 flavor（loader）分离；4 层 Framework→Platform→Industry→Tenant cascade ≈ 现有 #17 ConfigStore cascade。**别重建，只借 KB 那一层。** |
| **KB 摄取/源管理/向量检索** | **真空白** | 全仓无 embedding/vector/pgvector/RAG/chunk/ingest，无相关 dep。这是三层（Soul/Skill/**KB**）里唯一缺的一层。 |
| **统一存储桥** | **部分** | 已有 `resource/fs_resolver.ex`（URI 寻址、闭合 allowlist、traversal 守卫、per-type authority）+ `persistence.scope_by_workspace/2`（租户 chokepoint）。缺：单一 `Storage` 接口统一 Ecto+FS。低价值。 |
| **附件上传+存储** | **已覆盖** | PR-2b 已合（`world_uploads_controller.ex`、ws 分区存储、签名授权、anti-laundering、下载 token、UI）。v3/#1024 说的"租户禁用"只是个配置开关。仅 orphan GC 待办。 |
| **语音 ASR/TTS** | **空白但已有设计** | 无代码；但 `IMPLEMENTATION_ROADMAP.md §9c`（Phase 8）有 record-only 设计：控制/数据面分离、SFU、`Entity.MediaSession`（`media://`）+ `MediaSignaling` behavior。 |
| **计费看板 + SLA** | **真空白** | 无 billing/metering/invoice/SLA/quota 模块、dep、表。纯空白、耦合最低。 |
| 熔断/降级 | 空白 | v3 P3，小、可选。 |
| 插件系统 / `{{slot}}` / Admin Portal V2 / cc_pool / 两树 / Pipeline v2 | **不抄** | ezagent 对应物更强，见 §4。 |

## 2. lead 提出的三个再考虑

### 2.1 KB——必要建 `ezagent_domain_kb` 吗？→ **先不建，走 resource + kb 能力**

KB 需要三件事：① 源文档存储 ② chunk+embedding（向量库）③ 检索（向量搜索）。
- ① **存储已有载体**：`resource://<ws>/<type>/<name>`（`fs_resolver`，已带 allowlist+authority+traversal 守卫）——KB 源文档作为一个新 resource `<type>` 即可，不需要新 domain 的存储层。
- ②③ **是唯一新增**：一个向量存储 + 检索能力（pgvector 或外置）。这是个**能力**，不是一个需要独立生命周期/Kind 的 domain。

**建议**：KB **起步 = resource 层（存储）+ 一个 `kb` 向量/检索能力 + 一个 KB MCP 工具**（agent 通过它查）。**暂不建 `ezagent_domain_kb`**——等出现"KB 自己的实体生命周期/跨 workspace 的 KB 治理/独立扩展轴"等真实压力，再升格为 domain（YAGNI）。这样最小增量拿到 KB 能力，且不预先背上一个 domain 的边界成本。

### 2.2 CR 治理——可直接实施吗？→ **可以，且是扩展不是重建**

ConfigStore 已经把最难的不可变对象/指针/rollback/幂等做完了（§1 表）。CR 治理只是在其上加：
1. **草稿聚合**：一个 active draft 收集 N 个 delta（新增 `draft`/`change_request` 概念，引用 ConfigObject）。
2. **review 门**：lint + sandbox-vs-released diff + 二次确认（读现有 ConfigStore + projection 即可算 diff）。
3. **publish 仪式**：promote draft → 翻指针（`write_and_point`/repoint **已有**）→ 回收。
4. （后续）**Dream** 自动提案源——可选，手动 CR 跑通后再加。

**建议**：**可直接立项**，scope 写成"在 ConfigStore 原语上加 draft 聚合 + review 门 + publish 动作"，**严禁从零重建** rollback/版本机制（v3 的 version-history 页式 rollback 不如现有 repoint 原语干净）。

### 2.3 WS + 语音——非短期

- **WS 冻结契约**：机制已有（游标 replay + 角色路由），但形式化契约 + admin 端点是中期事；非阻塞当前产品环。
- **语音**：最大新面（媒体 WS、音频帧协议、ASR/TTS 适配、前端麦权限），依赖 WS 契约，照 §9c 实现。**标 later。**

## 3. 分步实现顺序（按 lead 口径调整）

| 阶段 | 内容 | 规模 | 层 | 依赖/理由 |
|---|---|---|---|---|
| **近期 A** | **CR 治理**（draft 聚合 + review 门 + publish），基于 ConfigStore | M | domain(identity/socialware) + console | 原语已在，纯扩展、价值高、无外部依赖；可立即立项 |
| **近期 B** | **KB 起步** = resource 存储 + 向量/检索能力 + KB MCP 工具（**不建新 domain**） | M→L | resource + 新 kb 能力 + 插件 | 最大真空白、产品价值最高；与 A 可并行；引入首个向量 dep |
| 中期 C | **WS 冻结契约**（envelope+版本握手+admin 端点） | M | core/socialware + 契约文档 | 机制已有=形式化+加 admin 端点；是语音/admin-live 的地基 |
| 后期 D | 计费 + 熔断 | M | 新 metering domain + console | 纯空白、零耦合、插空做 |
| 后期 E | 语音 ASR/TTS | L | 插件/channel + MediaSession Kind | 依赖 C；照 roadmap §9c |

**先起 2 个**：**CR 治理**（扩展、立即可做、纠正"重建"误判）+ **KB 起步**（价值长杆、走 resource+kb 不建 domain）。

## 4. ezagent 不该抄 v3 的地方（分歧是对的）

- **插件系统**：Behavior+Kind+URI+CapBAC+OTP-app > 声明式 plugin.yaml（评估亦认同"已超越"）。
- **`{{slot}}` 模板**：已被 `config_schema` 覆盖。
- **Soul/Skill 文件分层**：已被 `Role`（#54）覆盖；抄 v3 的 L0–L3 文件布局会把内容和 flavor 重新耦合，违背 #54。**只借 KB 那层。**
- **CR rollback 机制**：用现有 repoint-到-保留对象，别建 version-history 页式 rollback；只在其上建**工作流**。
- **cc_pool / Pipeline v2 / 两树**：模型不同（Agent flavor + LocalRuntime + 路由规则 + workspace 隔离 + kind_snapshots）。

## 5. 待 lead 拍的决策

1. CR 治理（近期 A）+ KB 起步（近期 B）是否立项 → 各起 SPEC？
2. KB 走"resource+kb 能力、暂不建 domain"是否认可？
3. WS 契约（中期 C）排在 CR/KB 之后是否 OK？语音确认 later？
