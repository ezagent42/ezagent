# Agent Entity × Flavor:映射关系与底层实例生命周期(v2.1)

日期:2026-07-09 · 起草基线 `364ccf6ba`(stable),**结论需按当前 HEAD 复核**
性质:**决策记录(decision record),不是实施规格(implementation spec)。**

> ⚠️ **实施前必读**:下述 Q1/Q3/Q4 是 Allen ratify 的**方向裁定**,**不代表实现已存在**。经 codex 对抗式 review(2026-07-09)确认,至少三处需要先补接口设计才能实施:
> 1. **`ContextRenderer` 契约**(Q1 的 replay 当前**无代码落点**)——见 §4.4
> 2. **`isolation` 能力位 schema**(`AgentFlavorRegistry.decl` 当前无此字段)——见 §5.3
> 3. **D2 的 runtime key**(与 reuse 复用 `agent_uri` 存在**未解决矛盾**)——见 §5.5
>
> v2→v2.1 变更(codex review 后修正):curl 分类纠错(stateful behavior)· config_dir 补第④类 · `message_routings` 已移除(copy+ref model)· URI 格式纠错 · 12 连锁位重写为状态清单 · D2 矛盾显式化 · Q1 对 cc-PTY 的可实施性标为**待 Allen 裁决**。

---

## 0. 一句话

`上层角色 → Recipe → flavor → 引擎实例` 这条链,静态映射和生命周期已落地且边界硬。Allen Q1 RULING:**全 flavor(含 cc-PTY)一律作无状态执行器,PTY 进程 = disposable cache,进程死亡为正常态;对话上下文权威在 PG `MessageStore`(session 键),rehydration 靠 PG 回放。** 三条实现线(异构无状态 run 契约·隔离能力位·存储分层)方向已定,按分期交付先落 D2 + cc-headless 首验。

---

## 1. 三层映射(已落地,边界硬)

| 层 | 实体 | 是什么 | 位置 |
|---|---|---|---|
| **Recipe** | `Ezagent.Agent.Recipe` | flavor-agnostic 沙盒内容配方(skills/plugins/prompt/script/behaviors/requested_caps/config) | core `recipe.ex:34,47-57` |
| **flavor** | `AgentFlavorRegistry` | 声明式 data:`flavor → {kind, template_class, instance_behaviors, cap_policy}` | domain_agent `agent_flavor_registry.ex:49-54` |
| **Entity** | `Ezagent.Entity.Agent` | `Recipe × flavor` materialize 出的运行时实例,URI **`entity://<workspace>/agent/<name>`** | `uri.ex:438-441`(`agent/2`);解析器强制 3 段 `:522` |

> **URI 格式纠错(v2.1)**:v2 曾写 `entity://agent/<flavor>_<name>`,那是 `entity/agent.ex:47` 的 **stale moduledoc**。当前 `Ezagent.URI.agent(workspace, name)` 生成 `entity://<workspace>/agent/<name>`,per-tenant scheme 强制带 workspace host。flavor 体现在 name 段前缀(`<flavor>_<...>`),不是独立 URI 段。**顺带:`Entity.Agent` 的旧 moduledoc 应修**。

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

**Rehydration 契约(Decision A 必答项)**:跨 backend 切换(cc→codex)时第②层保留但 CLI transcript 格式不同 → **对话连续性只能靠 `MessageStore` PG replay**(第①层)。

### ⚠️ 2.1a Q1 的实现缺口(codex review,critical)——待 Allen 裁决

**上述是目标架构,当前代码没有落点。** 现读证据:

- `MessageStore` 的 replay **只用于成员重连补发**(`in_session_since/2` → 重新 dispatch,`delivery.ex:379`),**不存在**"把历史渲染后喂给 flavor"的路径。
- cc-headless 只把**当前 `text`** 传给 SDK(`ezagent_cc_sdk_worker.py:131`);codex bridge 只把**当前 `content`** 发给 `turn/start`(`ezagent_codex_bridge.py:242`)。**没有 ContextRenderer。**
- **cc-PTY 尤其棘手**:启动的是**裸交互 `claude`**,无 `--resume`/`-p`(`spawn_plan.ex:78`);重启路径 `ensure_subprocess_alive/2`(`cc_agent.ex:826`)只是重新拉起 PtyServer,**不喂历史**。而 PTY 是**交互式 TUI,不是 request/response** —— 无法"喂"一段历史来恢复它的 context window。

**❓ 裁决点(回给 Allen)**:Q1 的"PTY = disposable"对 cc-PTY 而言,**等价于要求它迁到 headless `-p`/SDK 模式**(放弃 PTY 交互)。二选一:

- **(a)** 无状态语义**只覆盖 headless/remote/HTTP 档**,`cc`(PTY)显式标 `:per_instance_stateful`(只允许"进程重启 + 同 config home 尝试恢复"),不宣称跨 backend replay 等价;
- **(b)** 要求需要无状态的 role **一律走 `cc-headless`**,`cc`(PTY)仅留交互/调试用途。

**在此裁决前,Q1 对 cc-PTY 不可实施。** 实施前必须先补 **`ContextRenderer` 设计**:读取哪些 message、窗口/截断/token budget、system/tool/result 如何编码、幂等性测试、各 flavor 输入协议适配。

### 2.2 fresh-spawn 全路径(不变,all-or-nothing)

```
resolve_cascade_content → instantiate_workers(原子 fresh?) → post_spawn_obligations(lineage+bind)
  → record_sandbox_state(:cast sandbox.update_config) → mount_behavior_overlay(folded)
  → AgentFlavorAttributes.put → join(role_name_conflict→grant_at_join→facet)
```
失败任一步 → `undo_fresh_workers` + cleanup + grant revoke(`template_spawn.ex:455,824`)。新实例侧回滚现成。

### 2.3 readiness:进程活着 ≠ ready

bridge join 才 ready(`transport_readiness.ex:56,88,168`),积压消息走 `PendingDelivery` drain。R3(重新武装)待补 `failed→not_ready` 回环。

### 2.4 「换 flavor = 换实例」的状态清单(v2.1 重写)

> **codex review(high)**:v2 的"12 位"**遗漏了关键运行态**,不足以指导实现。下表补齐并标注 owner / 持久性 / key / switch 行为。

| # | 状态位 | owner | 持久性 | key | switch 行为 |
|---|---|---|---|---|---|
| 1 | 实例 URI | core | — | — | 新建 |
| 2 | `AgentFlavorAttributes` | domain_agent | ETS | instance_uri | put 新 / delete 旧 |
| 3 | `AgentRecipeAttributes` | domain_agent | ETS | instance_uri | put 新 |
| 4 | `AgentLineage` | core | **durable(Ecto+ETS)** | agent_uri | record 新 / forget 旧 |
| 5 | `WorkspaceRegistry` 绑定 | core | ETS | worker_uri | bind 新 / unbind 旧 |
| 6 | `:sandbox` slice | Kind | durable snapshot | worker_uri | 新 config_dir + 重跑凭据 cascade |
| 7 | 凭据 grant(#17 GrantRow) | credential | **durable(唯一索引)** | agent_uri | mint 新 / delete 旧 |
| 8 | behavior overlay | Kind | 进程内 | worker | mount 新(`curl_behaviors`≠`cc`) |
| 9 | role_name 成员边 | session | 成员边 meta | (entity×session) | 旧 leave 放名 → 新 join 占名 |
| 10 | member-cap | identity | durable grant | member_uri | revoke 旧 / grant 新 |
| 11 | 途中消息 | core | `PendingDelivery` | uri | 窗口内缓冲 / DLQ |
| 12 | 子进程 sidecar | plugin | OS 进程 | worker | SIGTERM 旧 / spawn 新(curl 无) |
| **13** | **`ReadyGate` / `TransportReadiness`** | core / domain_agent | ETS + gate | agent_uri | **必须重新武装**(`transport_readiness.ex:55`) |
| **14** | **`AgentBridge.Registry` / channel** | agent_bridge | 进程注册 | agent_uri | 旧 unbind,新 bind(bridge join 才 ready) |
| **15** | **codex app-server / bridge sidecar registry** | plugin_codex | 进程注册 | agent_uri | 旧 sidecar 停,新起(`plugin_codex/application.ex:69`) |
| **16** | **codex `thread_id` 文件**(第④类) | plugin_codex | **fs** | agent_uri | **跨 backend 必然失效**(`codex_agent.ex:271,279`) |
| **17** | **cc SDK sidecar registry + `claude_session_id`**(第④类) | plugin_cc | 进程注册 + fs | agent_uri | 同上(`sdk_sidecar.ex:31`;`cc_headless_agent.ex:92`) |

**关键点**:第 13-17 位是 v2 遗漏的。其中 **16/17 属 config_dir 第④类(runtime coordination metadata)** —— 跨 backend switch 时**必然失效**(thread/session 句柄不通用),这正是 rehydration 只能靠 PG replay 的根因;同 backend reset 时**应保留**。

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
| ③ runtime-accumulated | CLI 对话记忆、codex `rollout-*.jsonl`(`codex_agent.ex:451`)、agent 自改文件 | **不可复现** | ⚠️ 就是 state,Q1 拟降为 disposable(但见 §2.1a 缺口) |
| **④ runtime coordination metadata**(v2.1 新增) | `claude_session_id`(`cc_headless_agent.ex:92,106`)、codex `thread_id` 文件(`codex_agent.ex:271,279`) | **control-plane 句柄** —— 指向 backend 侧 session/thread | ⚠️ **既非投影、非凭据、也不能简单 disposable** —— 丢了它,同 backend 的 thread/session 连续性即断 |

**Decision A 的"state"精确指第③类**;第①/②类落盘不影响"无状态"定义(读者不能误读为"skills 落盘 = 有状态冲突")。

> **第④类是 codex review 补出的漏项(medium)**。它不可被简单归入任何一类:删了它,同 backend 的续接能力丢失;但它又不是对话内容本身。**需明确**:哪些可删、哪些需随实例迁移、哪些只在同 backend 内有效。这直接影响 §3 的 switch(跨 backend 时第④类必然失效)与 reset(同 backend 时应保留)。

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

### 5.3 隔离能力位(⚠️ **提案,未落代码**)

> **codex review(high)**:`AgentFlavorRegistry.decl` 当前只有 `kind/template_class/instance_behaviors/cap_policy`(`agent_flavor_registry.ex:49`),**无 `isolation` 字段**;bridge 层只有 `:subprocess_ws | :in_process_sync` 两档 transport class(`adapter_registry.ex:116`)。**本节是 schema 提案**,实施前需:加注册验证 + 默认拒绝 + per-flavor invariant test。否则 D1/D2 调度无依据。

**关键区分(v2.1 纠错)——"执行器无状态" ≠ "flavor 无状态"**:

| `isolation`(执行器/transport 维度) | 谁 | flavor behavior 是否持有 durable state? | reuse 共享执行器? |
|---|---|---|---|
| `:per_instance` | cc(PTY):常驻交互 process | 是(进程内 context window) | **否**→退化独立实例(D2) |
| `:per_thread`(串行) | cc-headless:`serializes`(`sdk_sidecar.ex:6`) | 是(SDK session,第④类句柄) | 可,需 per-sidecar turn 队列 |
| `:per_thread`(并发) | codex-remote/codex:app-server 多 thread | 是(thread,第④类句柄) | 可,每 session 一 thread(D1) |
| `:in_process_sync` | **curl / native** | **⚠️ curl 是 STATEFUL** —— 见下 | 需按 state 归属判定,**不能因"无子进程"就当安全** |

> **curl 分类纠错(v2.1,codex critical→high)**:v2 曾把 curl 归 `:stateless`,**错**。curl 的**transport** 无子进程(`in_process_sync`),但它的 **flavor behavior 持有 durable 对话状态** —— `Ezagent.ActionSet.CurlAgent` 的 `:curl_agent` slice 含 `conversation / last_error / last_tokens`,且"**ALL the durable `{:set, :conversation/...}` effects**"(`behavior/curl_agent.ex:28-40`)。
>
> 正确表述:**curl = stateless transport + stateful flavor behavior**。因此 **curl 不能作为 `:stateless` D1 的证明对象**。若要让 curl 真无状态,须把 `:curl_agent.conversation` 迁走,改由 `MessageStore` 渲染请求历史(即 §4.4 的 `ContextRenderer`)。

### 5.4 reuse 三策略 + 建议(D2 默认,Q2 收紧)

### ⚠️ 5.5 D2 的未解决矛盾(codex review,critical)——待 Allen 裁决

**"每 session 独立可写 runtime"与 reuse 的实现方式直接冲突,v2 用措辞掩盖了它。**

- reuse 复用的是**同一个 `agent_uri`**(`definition_agents.ex:179`:取 `reuse_agent_uri` 直接 `add_participant`,不 spawn、不 provision)。
- 而 config_dir / `CODEX_HOME` 是 **`agent_uri` 的纯函数**(`Sandbox.ConfigDir.path/2` 由 agent URI 的 workspace/name 构造,`config_dir.ex:48`;`home_runtime.ex:90`)。
- **推论**:同 `agent_uri` 跨两 session ⇒ **同一 config_dir、同一 sidecar registry key、同一 live worker**。代码里**不存在** per-session 的 runtime key。

**❓ 裁决点(回给 Allen)** —— 三选一,不能再含糊:

| 出路 | 含义 | 代价 |
|---|---|---|
| **(a)** D2 生成**新 runtime URI** | reuse 只复用 recipe/凭据来源,实例 URI 仍新建 | 退化成 fresh,省不了进程;"reuse"名不副实 |
| **(b)** 引入 runtime key `{agent_uri, session_uri}` | 真正的 per-session 可写 runtime | 要改**所有** config_dir / `CODEX_HOME` / sidecar registry / bridge registry 的 key |
| **(c)** 承认 reuse = **共享 runtime** | 诚实描述现状;另列 D3「共享身份但不共享记忆」为未来设计 | 放弃"独立可写 runtime"的承诺,reuse 跨 session 上下文相通 |

**在此裁决前,D2 的当前表述不可实施。**

---

- **D2(默认,安全)** — 共享身份 + **只读**凭据 + 每 session 独立可写 runtime(**⚠️ 实现方式待定,见 §5.5**)。
  - D2 不是"共享 config"(config_dir 是 `agent_uri` 纯函数 `home_runtime.ex:90`,共享 path = 写竞争+串台,曾被 `session_discriminator`(`entity/agent.ex:373,434`)修复)。
  - reuse 授权门:经 #1269 确认为 **false-positive**——provision 只是 join 第一步,真正的 operator→agent 凭据隔离在马下游 **Part C admission gate**(`membership.ex` `admission_pending?/2`):非 owner 且非 manages 的凭据型成员被 **PEND**,无 member-cap、花不了凭据,直到 owner `:approve_admission`。
- **D1(省资源)** — 共享执行器,仅对 `:per_thread`/`:stateless` flavor 允许。需 per-run session scope + 串行化(cc-headless)或 per-session thread(codex-remote)。
- **D3(显式声明)** — reuse 分"共享记忆"vs"共享身份不共享记忆"。

---

## 6. 存储分层:PG(权威)vs fs(缓存/导出)

### 6.1 现状

- **PG · event-sourcing 骨架**:`EventLog`(invocations)→ `SnapshotStore`(每 100 events)→ `MessageStore`(**每 session 一 row,copy+ref model**;`message_store.ex:80-81`)。

> **纠错(v2.1)**:v2 写 `messages + message_routings` join 表,那是 `message_store.ex:18-25` 的 **stale moduledoc**。代码 `:80-81` 明写「vestigial `message_routings` multi-routing **was removed** —— 跨 session 转发是**复制一条新 message** 进目标 session(copy+ref model)」;`in_session_since/2`(`:123`)直接按 `m.session_uri` 查,**无 JOIN**。→ §6.2「一条消息挂多 session」那行的论据随之作废(现在是复制,不是共享行)。
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

### 8.1 方向裁定(Allen ratify —— 已定)

| # | 决策 | 状态 |
|---|---|---|
| 1 | **上下文归属 A** — 权威在 PG `MessageStore`(session 键);flavor 应作无状态执行器 | ✅ 方向 ratify(Q1) |
| 1a | three-layer state(MessageStore / durable folder / disposable process) | ✅ 方向已定 |
| 1b | rehydration 靠 PG replay(跨 backend) | ✅ 方向已定 |
| 2 | **switch v0 = S1**(换实例弃旧) | ✅ 方向已定 |
| 3 | **reset v0 = R1**(原地重启);进程死 = normal case | ✅ 方向已定 |
| 4a | reuse 授权门 = false-positive(#1269,Part C gate 兜底) | ✅ 已闭合 |
| 5 | **per-role cardinality `one\|many`**;S3 = handoff/cutover | ✅ ratify(Q3) |
| 6 | **curl 生命周期 hook 退化**;completion/tool-loop 正交 | ✅ ratify(Q4) |

### 8.2 ⚠️ 实施阻塞项(codex review 2026-07-09 —— 必须先解)

| # | 阻塞项 | 严重性 | 位置 |
|---|---|---|---|
| B1 | **Q1 对 cc-PTY 不可实施** —— 裸交互 `claude` 无 `--resume`,PTY 是 TUI 非 req/resp,无法"喂"历史。需 Allen 在 (a) 只覆盖 headless 档 / (b) 强制 role 走 cc-headless 之间裁决 | **critical** | §2.1a |
| B2 | **`ContextRenderer` 无代码落点** —— MessageStore replay 当前只用于成员重连补发;cc-headless/codex 只传当前 text/content。需补完整接口设计(窗口/截断/token budget/编码/幂等) | **critical** | §4.4 |
| B3 | **D2 的 runtime key 矛盾** —— reuse 复用同 `agent_uri`,而 config_dir 是其纯函数;"每 session 独立可写 runtime"无实现路径。需 Allen 在 (a)/(b)/(c) 三条出路裁决 | **critical** | §5.5 |
| B4 | **`isolation` 能力位未建模** —— `AgentFlavorRegistry.decl` 无此字段;需 schema + 注册验证 + 默认拒绝 + invariant test | **high** | §5.3 |
| B5 | **curl 不是 `:stateless`** —— stateless transport + **stateful flavor behavior**(`:curl_agent.conversation` durable);不能作 D1 证明对象 | **high** | §5.3 |

### 8.3 已修正的事实错误(v2 → v2.1)

`message_routings` 已移除(copy+ref model)· URI 格式 `entity://<ws>/agent/<name>` · config_dir 补第④类(runtime coordination metadata)· 状态清单 12 位 → 17 位。

> **本稿是 decision record,不是 implementation spec。** B1–B5 解决前不进入实施;B1/B3 需 Allen 裁决,B2/B4 需补接口设计。

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
