# Agent Entity × Flavor:映射关系与底层实例生命周期(v2)

日期:2026-07-09 · 基线 HEAD `364ccf6ba`(= stable,今日晋级,含 P1-P3 #1266)
状态:**Q1/Q3/Q4 已 ratify** · 本稿吸收全部 Allen pre-grill 裁定,供合并前最终 review。

> v1.1→v2 变更:Q1(全 flavor PTY 无状态 + rehydration 契约)· Q3(per-role cardinality `one|many` + viewer 基线)· Q4(curl 退化生命周期 + completion/tool-loop 正交轴)· D2 收紧(只读凭据+独立 runtime + Part C 兜底)· Decision A 三分类(`stateless≠diskless`)· 命名对齐(#1253/#1255/#1261)· 删 ACT-2(已证 false-positive #1269)· 删 SkillRegistry provenance 注脚(已上 main #1266)。

---

## 0. 一句话

`上层角色 → Recipe → flavor → 引擎实例` 这条链,静态映射和生命周期已落地且边界硬。Allen Q1 RULING:**全 flavor(含 cc-PTY)一律作无状态执行器,PTY 进程 = disposable cache,进程死亡为正常态;对话上下文权威在 PG `MessageStore`(session 键),rehydration 靠 PG 回放。** 三条实现线(异构无状态 run 契约·隔离能力位·存储分层)方向已定,按分期交付先落 D2 + cc-headless 首验。

---

## 1. 三层映射(已落地,边界硬)

| 层 | 实体 | 是什么 | 位置 |
|---|---|---|---|
| **Recipe** | `Ezagent.Agent.Recipe` | flavor-agnostic 沙盒内容配方(skills/plugins/prompt/script/behaviors/requested_caps/config) | core `recipe.ex:34,47-57` |
| **flavor** | `AgentFlavorRegistry` | 声明式 data:`flavor → {kind, template_class, instance_behaviors, cap_policy}` | domain_agent `agent_flavor_registry.ex:49-54` |
| **Entity** | `Ezagent.Entity.Agent` | `Recipe × flavor` materialize 出的运行时实例,URI `entity://agent/<flavor>_<name>` | `entity/agent.ex:47,375` |

**两个锚点**:**recipe provenance**(记实例、不可变,`recipe_materializer.ex:217`);**role_name**(住 (entity×session) 成员边,会话内唯一,`membership.ex:44`)。同一 uuid 实例可在不同会话当不同 role。

**三条硬约束**:① flavor 焊死实例 URI → 换 flavor = 换实例;② role_name 会话内唯一 → 换实例被迫"先 leave 旧、再 join 新",有消息窗口;③ 新实例侧回滚现成(`undo_fresh_workers`),缺"旧↔新两侧编排"。

> **命名对齐(#1253 Decision #161)**:Definition(会话模板声明)→ Recipe(内容配方)→ Manifest(部署级分发件)→ Registry(注册表)。全文统一用此四层词汇,不混用。`Ezagent.Agent.RecipeResolver`(#1261 重命名)、`Ezagent.Agent.Recipe*` 点约定(#1255 arch gate)已随 rebase 吸收。

---

## 2. 生命周期(全 flavor 无状态——Allen Q1 RULING)

### 2.1 核心裁定:进程死亡为 NORMAL case

PTY 启动 `build_claude_cmd/3`(`spawn_plan.ex:81-83`)是无 `--resume`/`-p` 的裸交互 `claude`,进程常驻、只起一次(`spawn.ex:423`)。但网络/节点 churn 可随时弄挂 PTY → **进程死亡不是异常,是运营现实。从死亡恢复应为一等公民路径。**

由此确立 **state 三层归属**(RULING 15:50):

| 层 | 存哪 | 性质 | 证据 |
|---|---|---|---|
| ① 对话上下文 | PG `MessageStore`(session 键) | **权威源,backend-agnostic,可 replay** | core `message_store.ex:43-49` |
| ② workspace/folder | recipe 引用的 **durable config_dir** | 进程死亡仍在;同 backend `claude --continue` 恢复 CLI cache | `home_runtime.ex:90` `agent_config_dir/2` |
| ③ PTY 子进程 | disposable | **永不是真相源,只当缓存** | `spawn_plan.ex:58,81-83` |

**Rehydration 契约(Decision A 必答项)**:跨 backend 切换(cc→codex)时第②层保留但 CLI transcript 格式不同 → **对话连续性只能靠 `MessageStore` PG replay**(第①层)。无状态 run 每次都从 **MessageStore 取 session context → 渲染 → 喂 flavor**。cold-start restart 走已有 `ensure_subprocess_alive` self-heal + `Sandbox.post_init`(`template_spawn.ex:689`),从"异常恢复"升为"正常路径"。

### 2.2 fresh-spawn 全路径(不变,all-or-nothing)

```
resolve_cascade_content → instantiate_workers(原子 fresh?) → post_spawn_obligations(lineage+bind)
  → record_sandbox_state(:cast sandbox.update_config) → mount_behavior_overlay(folded)
  → AgentFlavorAttributes.put → join(role_name_conflict→grant_at_join→facet)
```
失败任一步 → `undo_fresh_workers` + cleanup + grant revoke(`template_spawn.ex:455,824`)。新实例侧回滚现成。

### 2.3 readiness:进程活着 ≠ ready

bridge join 才 ready(`transport_readiness.ex:56,88,168`),积压消息走 `PendingDelivery` drain。R3(重新武装)待补 `failed→not_ready` 回环。

### 2.4 「换 flavor = 换实例」牽動 12 位(不变)

实例 URI · AgentFlavorAttributes · RecipeAttributes · AgentLineage · WorkspaceRegistry · `:sandbox` slice · 凭据 grant · behavior overlay · role_name 成员边 · member-cap · 途中消息 · 子进程 sidecar(curl 无)。关键简化:第 6 位 `:sandbox` context 不再是"迁 config_dir",而是"**从 MessageStore 重放**(rehydration 契约)";第 12 位 cc-PTY 不再需"迁移子进程上下文"(可弃)。

---

## 3. switch / reset — 因 Q1 RULING 大幅简化

### 3.1 switch(跨 flavor)

| 版本 | 说明 | 现成度 |
|---|---|---|
| **S1 换实例弃旧(v0)** | spawn→ready→旧 leave→新 join→旧 SIGTERM。**进程=可弃,不丢上文(MessageStore replay 恢复)** | 高 |
| S2 迁移内容 | **因 Q1 作废**(不必迁 config_dir,PG replay 足够) | — |
| S3 role 指针重绑 | 撞 role_name 唯一;Q3 后走 **handoff/cutover**(单活跃+一 pending,原子换绑),非 fan-out | ❓ 待 Q3 落地 |

### 3.2 reset(回干净态)

| 版本 | 说明 | 现成度 |
|---|---|---|
| **R1 原地重启(v0)** | terminate sidecar → `ensure_subprocess_alive` → 从 MessageStore replay。身份零改动 | 高 |
| R2 清 sandbox 重建 | `destroy_config_dir` 有;受 Q1 简化(replay 替代迁内容) | 中 |
| R3 重新武装 readiness | 缺 `failed→not_ready`;**Q1 后必要性降低**(进程死=正常,直接 restart 而非 re-arm) | 低优先级 |

---

## 4. Decision A 实质化:config_dir 三分类 + `stateless ≠ diskless`

### 4.1 决策

- **上下文权威** = PG `MessageStore`(session 键,flavor-agnostic)
- **flavor** = 无状态执行器,每次 run 由上层喂完整 context
- **PTY 进程** = disposable,永非真相源(Q1 RULING)

### 4.2 `stateless ≠ diskless` — config_dir 三分类(必须区分)

| 类 | 内容 | 性质 | 与无状态相容? |
|---|---|---|---|
| ① recipe-projected | skills(幂等拷贝 `orchestrator_bootstrap.ex:43,148`)、CLAUDE.md(由 recipe 写出 `home_runtime.ex:313-315`) | 纯函数投影,determinism 锚 `recipe/compose.ex:11-13`"同 recipe×任意 flavor→字节相同" | ✅ destroy-rebuild 可复现,stateless≠diskless |
| ② credential | `.credentials.json`(`cc_agent.ex:209`)、`auth.json` | cascade 可恢复 | ✅ restorable |
| ③ runtime-accumulated | CLI 对话记忆、codex `rollout-*.jsonl`(`codex_agent.ex:451`)、agent 自改文件 | **唯一真不可复现** | ⚠️ **就是 state,被 Q1 RULING 降为 disposable** |

**Decision A 的"state"精确指第③类**。第①/②类是 Recipe 的纯函数投影/可恢复凭据,落盘不影响"无状态"定义。读者不能误读为"skills 落盘 = 有状态冲突"。

### 4.3 异构无状态化:四个实现 + 首验对象

| 实现 | 内容 | 首验 flavor |
|---|---|---|
| ① 统一 run 契约 | `run(rendered_context, input) → {reply, artifacts}`,turn 间不留 state,放 AgentBridge adapter(P12) | cc-headless / codex-remote |
| ② context 渲染器(上层) | 从 MessageStore 按 session 取历史→翻各 flavor 输入 | 共通 |
| ③ 绕过 flavor 自身 session | cc 走 headless/`-p`;codex 一次性 thread | cc-headless / codex-remote |
| ④ adapter 声明能力位 | `stateless_capable?` + `isolation`(见 §5) | 共通 |

**首验路径**(Q1 RULING 后在所有 flavor 上成立):

| 对象 | 机制 | 隔离档位 | 先行原因 |
|---|---|---|---|
| cc-headless(验证"串行 per_thread") | `ClaudeSDKClient` sidecar,`query(text, session_id)`,`sdk_sidecar.ex:94`;**serializes**(`:6`)→需 turn 队列 | `:per_thread` 串行 | 接口已就位,每次 query 拼 MessageStore context |
| codex-remote(验证"并发 per_thread") | app-server + bridge sidecar,conversation 单位 `thread_id`;app-server 原生多 thread,单 `thread_id`→要扩 per-session | `:per_thread` 并发 | 每 session 一 thread,免串行 |
| curl / native(验证":stateless") | 本来就无状态,走 `in_process_sync`,`agent_bridge.ex:128,331` | `:stateless` | 天然满足,D1 安全 |

---

## 5. 会话隔离 + cardinality(Allen Q3 ratify:per-role `one|many`)

### 5.1 viewer 验证结论(ACT-1 + codex 交叉验证)

| 点 | 结论 | 关键证据 |
|---|---|---|
| hello 是否声明 viewer/human? | ✅ **是** — deploy-seed `manifest.yaml:27-28` 有 `role_name: viewer, fill: human` | `manifest.yaml:18-47`;`Demo.Hello` moduledoc 权威声明"is the one source of truth"(`hello.ex:5-24`) |
| 有 `from_role: viewer` 路由? | ✅ **是** — `manifest.yaml:29-36` 有 `from_role: viewer → responser` | `manifest.yaml:29-36` |
| 匿名访客带 role_name 吗? | ❌ **不带** — `AnonAdmission` join 只传 `%{member: anon_uri}`,无 role_name | `anon_admission.ex:100-107` |
| role_name_conflict 冲突? | ❌ **不冲突** — `role_name_conflict(_, _, nil) → :ok` | `members.ex:67` |
| `from_role: viewer` 会 fire 吗? | ❌ **永不 fire**(对匿名访客)——`match?` 读 sender 的 `role_name` facet,匿名无 facet | `matcher.ex:178-179,322-326` |
| **消息到 agent 吗?** | ✅ **到** — 走框架 `system_default` 规则 `$session_members`,广播全部成员 | `resolver.ex:17-25`;`session.ex:540,612-635` |

**一句话**:viewer 唯一性冲突 **不成立**(anon 不占 role_name);`from_role: viewer` 对匿名访客空转但交付不走空(`$session_members` 兜底);**真正的问题是** viewer role 有意义但匿名访客不在它下面,导致 `from_role: viewer` 规则永远不被匿名触发。

### 5.2 per-role cardinality(Allen Q3 ratify,plan §1 5 分钟项)

**occupancy 是 per-role policy,不是全局不变式:**

| `cardinality` | 语义 | 谁 |
|---|---|---|
| `one`(默认) | accountable 单持有者,当前语义 | orchestrator / builder / concierge / responser |
| `many` | 人类自由附加;`{:role}` fan-out 到所有 edge | **viewer**(hello 真实用例) |

- S3 换实例跟 cardinality **正交**,仍走 **handoff/cutover**(单活跃+一 pending,原子换绑)。
- fan-out 到群组的下层实现走 **Legend + `$session_members`**(`legend.ex:1,7` `member_set`),不走重载 role_name。
- Q3 让 viewer 从"隐式(anon 不占 role_name)升为**显式**(role + cardinality:many),并连带让 `from_role: viewer → responser` 对带 viewer role 的 human 生效。

### 5.3 隔离能力位(修正:四档)

| `isolation` | 谁 | reuse 共享执行器? |
|---|---|---|
| `:per_instance` | cc(PTY):常驻 process | **否**→退化独立实例(D2) |
| `:per_thread`(串行) | cc-headless:`serializes` | 可,需 per-sidecar turn 队列 |
| `:per_thread`(并发) | codex-remote/codex:app-server 多 thread | 可,每 session 一 thread(D1) |
| `:stateless` | curl / native | 天然安全(D1) |

### 5.4 reuse 三策略 + 建议(D2 默认,Q2 收紧)

- **D2(默认,安全)** — 共享身份 + **只读**凭据 + **每 session 独立可写 runtime**。复用 recipe/凭据/URI,但每 session 起独立执行器。
  - D2 不是"共享 config"(config_dir 是 `agent_uri` 纯函数 `home_runtime.ex:90`,共享 path = 写竞争+串台,曾被 `session_discriminator`(`entity/agent.ex:373,434`)修复)。
  - reuse 授权门:经 #1269 确认为 **false-positive**——provision 只是 join 第一步,真正的 operator→agent 凭据隔离在马下游 **Part C admission gate**(`membership.ex` `admission_pending?/2`):非 owner 且非 manages 的凭据型成员被 **PEND**,无 member-cap、花不了凭据,直到 owner `:approve_admission`。
- **D1(省资源)** — 共享执行器,仅对 `:per_thread`/`:stateless` flavor 允许。需 per-run session scope + 串行化(cc-headless)或 per-session thread(codex-remote)。
- **D3(显式声明)** — reuse 分"共享记忆"vs"共享身份不共享记忆"。

---

## 6. 存储分层:PG(权威)vs fs(缓存/导出)

### 6.1 现状

- **PG · event-sourcing 骨架**:`EventLog`(invocations)→ `SnapshotStore`(每 100 events)→ `MessageStore`(messages+message_routings · `message_store.ex:18-49`)。
- **文件系统 · config_dir**:凭据(①)+ recipe 投影(③ skills/CLAUDE.md)+ runtime SDK session(④ codex jsonl/cc `~/.claude`)。配合 §4.2 三分类:①③ = 可复现投影,④ = disposable cache。

**结论**:对话历史/上下文**已在 PG,不是 fs**。白板 `fs:log` 若指文件日志存历史,与现状不符,也不建议改主存。

### 6.2 DB vs 文件(针对历史/上下文)

| 维度 | PG | 文件 |
|---|---|---|
| 按 session/时间/id 查询 replay | ✅ SQL JOIN+LIMIT | ✗ 随机查难 |
| 一条消息挂多 session | ✅ `message_routings`(#40) | ✗ 跨文件自建索引 |
| 事务/幂等/一致性 | ✅ upsert+unique | ✗ 无事务 |
| **按 session 隔离(§5)** | ✅ `session_uri` 列,天然分区 | ✗ 共享文件自己切 |
| append 吞吐/PTY 原始流 | 中 | ✅ 顺序写快 |
| 大附件/产物 | ✗ 不塞 blob | ✅ 天生适合 |
| 离线 cat/grep/归档 | 中 | ✅ 直接看(jsonl) |

### 6.3 fs:log 的定位

`fs:log` 不是主存,而是从 EventLog/MessageStore **投影出的可选追加审计/导出流**(cat/grep/归档、喂无状态 run),真相源仍是 PG。文件专接**附件/大产物**(config_dir 或对象存储)+**PTY 录制**(若需)。

---

## 7. curl 统一(退化生命周期,Q4)

- **声明** `:stateless` + `:in_process_sync`(`agent_bridge.ex:128,331`)——**没有**子进程/config_dir/PTY 生命周期(`bridge_adapter.ex:22`「NO subprocess and NO WebSocket」)。
- **退化**:ready=恒真;fail=`last_error` 数据(`behavior/curl_agent.ex:35-37`);reset = `reset_conversation`(:91);switch = `configure`(:99)。**同一套能力位接口,每个 hook 退化**,不分叉。
- **completion vs tool-loop 与 flavor 正交**:curl 纯 completion(`bridge_adapter.ex:105`,零 tool);tool-loop 只在 cc MCP orchestrator(`mcp_server.ex:329`)。**真做 tool-loop 应在 flavor 之上起共享轴驱动任意 flavor**(含 curl)。保护不变式:flavor = 可互换 completion backend(`recipe/compose.ex:11-13`)。

---

## 8. 决策清单(v2)

| # | 决策 | 状态 |
|---|---|---|
| 1 | **上下文归属 A** — MessageStore(session 键);flavor = 无状态;PTY = disposable | ✅ 已 ratify(Q1 RULING) |
| 1a | three-layer state(MessageStore / durable folder / disposable process) | ✅ 已定 |
| 1b | rehydration 契约(跨 backend 靠 PG replay) | ✅ 已定(Decision A 必答) |
| 1c | config_dir 三分类(recipe-projected/credential/runtime) | ✅ 已定(§4.2) |
| 2 | **switch v0** — S1 换实例弃旧;不丢上文(PG replay) | ✅ 已定 |
| 3 | **reset v0** — R1 原地重启;R3(回环)降优先级(进程死=正常) | ✅ 已定 |
| 4 | **reuse 隔离默认** — D2(只读凭据+独立 writable runtime);`:per_thread`/`:stateless` 允许 D1 | ✅ 已定(Q2 收紧) |
| 4a | reuse 授权门 false-positive(#1269,Part C gate 兜底) | ✅ 已闭合 |
| 5 | **per-role cardinality** — `one|many`;S3 = handoff/cutover | ✅ 已 ratify(Q3,plan §1) |
| 6 | **curl 统一** — 退化生命周期,同一能力位接口;completion/tool-loop 正交 | ✅ 已 ratify(Q4) |

> 全部 ❓ 已收敛。本稿可转正式(去 WIP)。

---

## 9. 三条实现线依赖(更新)

```
Q1 RULING(全 flavor 无状态 + rehydration)
   ├─► 线1 无状态 run 契约(§4.3) —— cc-headless + codex-remote 首验
   │      dependent: 线2 D1(共享执行器)
   │
   ├─► 线2 隔离能力位(§5.3-5.4) —— D2 可独立先落;D1 依赖线1
   │
   └─► 线3 存储分层(§6) —— PG 已是权威;config_dir 三分类固化
```

**分期交付**:线3(固化 PG + config_dir 三分类)先行;线2 D2(安全隔离)独立可落;线1 首验从 cc-headless 起步→codex-remote→回头让 reuse 走 D1。S2(内容迁移)/S3(多 member)/curl 统一(退化)已收口;app.ex dead-code drift(§6.4)登记清理。

---

## 附录:本稿引用的外部变更

| PR | 内容 | 对本稿影响 |
|---|---|---|
| #1269 | reuse-join 授权门 false-positive(Part C gate) | ACT-2 作废 |
| #1266 | SkillRegistry P1-P3 合入 main | DOC-prov(provenance 注脚)删除 |
| #1253 | Decision #161 四层词汇(Definition/Recipe/Manifest/Registry) | 命名对齐 |
| #1261 | `RecipeResolver` 重命名 | `Ezagent.Agent.RecipeResolver` 引用更新 |
| #1255 | `Recipe*` 点约定 + arch gate | `Ezagent.Agent.Recipe*` 类名前缀 |
| #1233 | hello 迁部署级 seed 车道(`manifest.yaml`) | viewer 结论:moved from `app.ex` 死代码→`manifest.yaml` 权威源 |
