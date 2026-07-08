# Agent Entity × Flavor:映射关系与底层实例生命周期(v1.1)

日期:2026-07-08 · 基线 HEAD `b260b09aa` · 全部断言现读,带 `file:line`
状态:**决策 A(上下文归属)已确认** → 下沉出三条实现线(异构无状态化 / 隔离能力位 / 存储分层)

> v0→v1 变更:决策 A 拍板"上下文放上层、flavor 作无状态执行器";新增 §4 异构无状态化、§5 隔离能力位、§6 存储分层(PG vs fs);§7 决策清单相应更新。
> v1→v1.1 变更:现读 cc-headless/codex-remote runtime;新增 §4.5 首验对象;**修正 §5.2 隔离能力位表**——`cc-headless` 从 `:stateless` 改归 `:per_thread`(串行),`cc` 拆成 PTY(`:per_instance`)与 headless 两档。

---

## 0. 一句话

白板 `上层角色 → Recipe → flavor → 引擎实例` 这条链,静态映射与大半生命周期已落地且边界硬。**v1 已定:上下文权威在上层(PG `MessageStore`,session 键),flavor 降为无状态执行器。** 由此收敛出三条要做的实现线:(1) cc/codex **异构**下的无状态 run 契约;(2) flavor 层的**隔离能力位**(尤其 reuse 共享执行器);(3) **存储分层**(PG 权威 / fs 缓存)。switch/reset 因决策 A 大幅简化。

---

## 1. 三层映射(已落地,边界硬)

| 层 | 代码实体 | 是什么 | 位置 |
|---|---|---|---|
| **Recipe** | `Ezagent.Agent.Recipe` | flavor-agnostic 的沙盒内容配方(skills/plugins/prompt/script/behaviors/requested_caps/config)。禁携带任何 flavor 字段,`new/1` fail-closed | core `recipe.ex:34,47-57,94-116` |
| **flavor** | `AgentFlavorRegistry` | 声明式 data:`flavor → {kind, template_class, instance_behaviors, cap_policy}` | domain_agent `agent_flavor_registry.ex:49-54,67,142` |
| **Entity(实例)** | `Ezagent.Entity.Agent` | `Recipe × flavor` materialize 出的运行时实例,URI `entity://agent/<flavor>_<name>` | `recipe_materializer.ex:87`;URI `entity/agent.ex:47` |

**两个锚点**:`recipe provenance`(从哪个 recipe build,记实例上、不可变,`recipe_materializer.ex:217`);`role_name`(会话里叫什么角色,只住 (entity×session) 成员边,会话内唯一,`membership.ex:44`)。同一 uuid 实例可在不同会话当不同 role。

**三条硬约束**:① flavor 焊死实例 URI(`entity/agent.ex:375`)→ 换 flavor 只能换实例;② role_name 会话内唯一 → 换实例被迫"先 leave 旧、再 join 新",有消息窗口;③ 新实例侧回滚现成(`undo_fresh_workers`),缺"旧↔新两侧编排"。

---

## 2. 生命周期:fresh-spawn 全路径 + 12 连锁位

### 2.1 全路径(`TemplateSpawn.spawn_from_template_content/5`,all-or-nothing)

```
resolve_cascade_content   ── mint #17 凭据 grant(按 agent_uri 唯一)              :260
   ▼ instantiate_workers   ── 插件 template_class.instantiate/3 → 原子 fresh?     :374,:579
   ▼ post_spawn_obligations── record_lineage + bind_workspace                     :802,:803
   ▼ record_sandbox_state  ── :cast sandbox.update_config → :sandbox slice         :449,:617
   ▼ mount_behavior_overlay── Kind.mount(recipe×flavor folded behaviors)          :450
   ▼ AgentFlavorAttributes.put ── flavor 焊实例                                    :451
   ── join ── role_name_conflict → grant_at_join → put_member_facets     membership.ex:48,88,39
失败任一步 → undo_fresh_workers(terminate+unbind+lineage forget)+cleanup+grant revoke  :455,:824
```

### 2.2 readiness:进程活着 ≠ ready

`require_transport_join → :not_ready`(`transport_readiness.ex:56`);真 bind 事件 → drain + `:ready`(`:88`);超时 5s → `mark_failed`(`:168`)。

### 2.3 换 flavor = 换实例,牵动 12 位

实例 URI · AgentFlavorAttributes · AgentRecipeAttributes · AgentLineage · WorkspaceRegistry 绑定 · `:sandbox` slice · 凭据 grant · behavior overlay · role_name 成员边 · member-cap · 途中消息 · 子进程 sidecar(curl 无)。(逐位 file:line 见 v0 表,未变。)

---

## 3. switch / reset 候选语义(6 版)+ 决策 A 后的简化

| 操作 | 版本 | 现成度 | 说明 |
|---|---|---|---|
| switch | **S1 换实例弃旧** | 高 | 复用 spawn/rollback + leave/join。**因 A:上下文在 MessageStore,弃旧不丢上下文** |
| switch | S2 迁移内容 | 低 | **因 A 可作废**(不必迁 config_dir) |
| switch | S3 role 指针重绑 | 冲突 | 撞 role_name 会话内唯一,需先松绑 |
| reset | **R1 原地重启** | 高 | 身份零改动,冷启动 self-heal 已有(`template_spawn.ex:689`) |
| reset | R2 清 sandbox 重建 | 中 | `destroy_config_dir` 有,内容重建要编排 |
| reset | R3 重新武装 readiness | 缺口 | 无 `failed→not_ready` 回环,要新加 |

**决策 A 的红利**:switch/reset 12 连锁位的第 6 位(`:sandbox` context)从"迁 config_dir"退化为"重放 MessageStore",S1/R1 成为干净 v0。

---

## 4. 【已确认 A】上下文放上层,flavor 作无状态执行器 —— 异构与实现

### 4.1 决策

- **上下文权威**:ezagent `MessageStore`(PG,**键在 session**,flavor-agnostic,`core message_store.ex:43-49`)。
- **flavor**:无状态执行器,每次 run 由上层喂完整 context;config_dir 里 SDK 的 session 文件降为**可弃缓存**。

### 4.2 现状是 stateful 且异构(要拿掉的正是这层)

| flavor | 记忆载体(现状) | 证据 |
|---|---|---|
| cc(PTY/TUI) | claude 进程 + `CLAUDE_CONFIG_DIR`/`~/.claude` 交互 session | cc_agent/spawn.ex:128 |
| cc-headless | `ClaudeSDKClient` Python sidecar(无 PTY,更可控) | cc_headless_agent.ex:1-7 |
| codex | app-server **thread**("share one context") | codex_agent.ex:276 |
| curl / native / py | 无——每次自带完整输入 | curl_agent/application.ex:109 |

异构本质:cc 是长驻交互 session,codex 是 app-server thread,都把上文锁在运行时里。

### 4.3 需要的 4 块实现

1. **统一无状态 run 契约**(AgentBridge adapter 层,P12 把协议差异关 adapter):`run(rendered_context, new_input) → {reply, artifacts}`,turn 间不留状态。现 `AgentBridge.deliver` 只投递一条、靠子进程记忆(`agent_bridge.ex:11-70`),要改成携带渲染好的 context。
2. **context 渲染器**(上层、flavor-agnostic):从 `MessageStore` 按 session 取历史 → 翻成各 flavor 输入(curl=messages 数组;cc-headless=SDKClient 一次性输入;codex=fresh thread + replay)。
3. **绕过 flavor 自身 session**:cc 走 `-p`/headless 而非 `--resume`;codex 一次性 thread 不复用 thread_id。
4. **adapter 声明能力位**:`stateless_capable?` + `isolation`(见 §5.2)。

### 4.4 关键子决策

**cc 的 PTY 交互式 TUI 是长驻会话,强行无状态代价大**。→ 无状态语义优先落 `cc-headless`/`codex-remote`/`curl`;需要无状态的 role 一律走 `cc-headless`,而把 `cc`(PTY)当作 stateful 特例(交互/调试用)。**❓ 待确认:cc-PTY 是否排除在无状态语义外。**

### 4.5 首验对象:cc-headless(串行)+ codex-remote(并发)

两者都已 headless(无 PTY/TUI),turn 是"请求/响应"或"app-server thread",最接近无状态 run,应作首验:

- **cc-headless**:`ClaudeSDKClient` sidecar,`query(agent_uri, text, session_id) → {:ok, map}`(`sdk_sidecar.ex:94,142-150`),接口已是无状态形状;但一个 SDK client **serializes**(`sdk_sidecar.ex:6`)→ `:per_thread` **串行**,需 per-sidecar turn 队列。落法:每次 query 把 MessageStore 的 session context 拼进 `text`(真无状态),或用 `session_id` 对齐 ezagent session。
- **codex-remote**:app-server(shared control plane,`app_server.ex:5-7`)+ bridge sidecar,conversation 单位 `thread_id`;app-server **原生多 thread**,但现只用一个(`codex_remote_agent.ex:164,180`)→ `:per_thread` **可并发**。落法:每个 ezagent session 映一个 codex `thread_id`。
- **`cc`(PTY)** 留作 stateful 特例(交互/调试)。

> 结论:首验用 `cc-headless` 验"串行 per_thread + 队列",`codex-remote` 验"并发 per_thread + 每 session 一 thread";两条打通后无状态 run 契约即成型,curl/native 天然满足。

---

## 5. 会话隔离 + flavor 隔离能力位

### 5.1 隔离性矩阵(现状)

| 背景 | 执行器 / config_dir | 上下文 | 隔离性 | 靠什么 |
|---|---|---|---|---|
| fresh · 单 session | 独立 | 独立 | ✅ 天然 | session_discriminator(`entity/agent.ex:433`) |
| 同 session · 多人 | 共享 | 共享(有意) | 有意共享 | turn / visibility |
| **reuse · 跨 session** | **共享同一实例** | **串**(`codex_agent.ex:276`) | ❌ **缺** | 无 |
| curl / native | 共享 stateless | 每 run 自带 | ✅ 天然 | 本就无状态 |

`reuse_existing_agent`(`definition_agents.ex:179`)复用同一 `agent_uri` → 同一子进程/config_dir/thread → 两 session 上文相串。**这是当前真空。**

### 5.2 隔离能力位(做成 adapter 声明)

| `isolation` | 谁 | reuse 能否共享执行器 |
|---|---|---|
| `:per_instance` | `cc`(PTY):一实例一会话 | **否** → 退化独立实例(D2) |
| `:per_thread`(串行) | `cc-headless`:一 sidecar 多 `session_id`,但 serializes | 可,需 per-sidecar turn 队列 |
| `:per_thread`(可并发) | `codex-remote`/`codex`:app-server 多 thread | 可,**每 session 一 thread** 隔离 |
| `:stateless` | `curl` / `native` | 天然安全,每 run 自带 context |

> v1.1 修正:v1 曾把 `cc-headless` 误归 `:stateless`。现读 `sdk_sidecar.ex:6`("serializes query+receive_response")——它是**串行的 `:per_thread`**(一个 SDK client 一次一 turn),不是并发无状态。

### 5.3 reuse 三策略 + 建议

- **D1 无状态 + per-run session scope + 串行化**(依赖 §4):共享执行器,每 run 喂该 session context;单执行器同刻只能跑一个 session 的 turn → per-executor turn 队列。codex 多 thread 免串行,cc 单进程必串行。
- **D2 只共享身份/config,不共享运行时**:复用 recipe/凭据/URI,每 session 仍起独立执行器 → 退化 fresh 隔离,安全但不省进程。
- **D3 显式声明**:reuse 分"共享记忆"(有意跨 session 同上文)vs "共享身份不共享记忆"。

**建议:默认 D2(安全);`:per_thread`/`:stateless` 才允许 D1(省资源);`:per_instance` 的 cc-PTY 永远 D2。**

---

## 6. 存储分层:PG(权威)vs fs(缓存/导出)

### 6.1 现状(都现读)

- **PG · event-sourcing 骨架**:`EventLog`(invocations,追加,`event_log.ex:66,156`)→ `SnapshotStore`(kind_snapshots,每 100 events + terminate,`snapshot_store.ex:6-8`)→ `MessageStore`(messages + message_routings,历史真相源,`message_store.ex:18-49`)。
- **文件系统 · config_dir**:凭据(auth.json / .credentials.json)+ flavor SDK session(codex thread/jsonl、cc `~/.claude`)。**即 §4 要降级的缓存。**

**结论**:对话历史/上下文**已经在 PG,不是 fs**。白板 `fs:log` 若指"文件日志存历史",与现状不符,也不建议改主存。

### 6.2 DB vs 文件(针对历史/上下文)

| 维度 | PG(现状) | 文件 fs:log |
|---|---|---|
| 按 session/时间/id 查询、replay | ✅ SQL JOIN + LIMIT | ✗ append 好写,随机查难 |
| 一条消息挂多 session(reuse/多路) | ✅ `message_routings`(Decision #40) | ✗ 跨文件自建索引 |
| 事务/幂等/一致性 | ✅ 同步 upsert + unique index | ✗ 无事务,崩溃半写 |
| **按 session 隔离(§5)** | ✅ `session_uri` 列,天然分区 | ✗ 共享文件要自己切 |
| append 吞吐 / PTY 原始流 | 中 | ✅ 顺序写快 |
| 大附件 / 产物 | ✗ 不塞 blob | ✅ 天生适合 |
| 离线 cat/grep / 归档 | 中 | ✅ 直接看(codex jsonl) |
| 统一备份/迁移 | ✅ 一处 DB | 中(散在各 config_dir) |

### 6.3 fs:log 的合理定位

不是主存,而是从 EventLog/MessageStore **投影出的可选 append-only 审计/导出流**(cat/grep/归档、喂无状态 run),真相源仍是 PG。文件存储专接**附件/大产物**(config_dir 或对象存储)与 **PTY 原始流录制**(若需)。

---

## 7. 决策清单(v1)

| # | 决策 | 状态 |
|---|---|---|
| 1 | **上下文归属 A** — flavor = 无状态执行器,上下文权威在 MessageStore(session 键) | ✅ **已确认** |
| 1a | cc-PTY 是否排除在无状态语义外(需无状态 role 走 cc-headless) | ❓ 待定 |
| 2 | **switch v0** — S1 换实例弃旧;窗口内消息缓冲 vs 拒 | ❓ 建议 S1 |
| 3 | **reset v0** — R1 原地重启;是否补 R3(failed→not_ready 回环) | ❓ 建议 R1 |
| 4 | **reuse 隔离默认** — D2(安全)/ 按 isolation 能力位允许 D1 | ❓ 建议 D2 默认 |
| 5 | **role 多 member** — role_name 会话内唯一是否松绑(解锁 S3) | ❓ 待定 |
| 6 | **curl 分叉** — 无子进程的 ready/fail/reset/switch 是否统一抽象 | ❓ 待定 |

---

## 8. 三条实现线的依赖

```
决策 A(已定)
   ├─► 线1 异构无状态 run 契约(§4)──┐
   │      cc-headless/codex/curl 先行  │
   │                                   ▼
   ├─► 线2 隔离能力位(§5)── reuse D1 依赖线1;D2 可独立先落
   │
   └─► 线3 存储分层(§6)── PG 已是权威,fs 降缓存 + 可选导出流
```

**交付边界**:先落线3(确认/固化 PG 权威 + config_dir 降缓存)与线2 的 D2(安全隔离),线1 从 `cc-headless` 起步验证无状态 run 契约,再回头让 reuse 走 D1。S2/S3/role 松绑/curl 统一显式 defer,走 Allen grill 进 GLOSSARY Decision Log。
