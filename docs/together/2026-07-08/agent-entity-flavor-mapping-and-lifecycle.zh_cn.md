# Agent Entity × Flavor:映射关系与底层实例生命周期(v2.4)

日期:2026-07-10 · 起草基线 `364ccf6ba`(stable),**结论需按当前 HEAD 复核**
性质:**决策记录(decision record),不是实施规格(implementation spec)。**

> ## 核心 framing(v2.2,实测确立)
>
> **引擎的 session = 可弃缓存。PG `MessageStore` = 权威。**
> - **同 backend**:命中缓存 → 走引擎自己的 CLI-native resume(快、零 token)
> - **跨 backend / 缓存失效**:回源 → 从 PG 重建
>
> Allen 的「flavor = 无状态执行器」由此获得精确含义:**不是"每次都从 PG 喂",而是"引擎的记忆永远只是缓存,丢了能重建"。**

> ⚠️ **实施前必读**:Q1/Q3/Q4 是 Allen ratify 的**方向裁定**。经 codex 对抗式 review ×2(本 session + Codex 独立 review),当前状态:
> - **B1(cc-PTY 恢复)** —— ✅ **已实测关闭**,降为 low(两行 argv),见 §2.1a
> - **B2(跨 backend replay)** —— 🟡 **降级为 future capability**,独立 SPEC 排期,见 §4.4
> - **B3(D2 runtime key)** —— ✅ **已裁决(c)**,承认 reuse = 共享 runtime,见 §5.5
> - **B4(isolation schema)** —— 🟠 **Step 1 不关闭 B4**,需 AgentFlavorRegistry 完整 schema,见 §5.3
> - **B5(curl 分类)** —— ✅ 已修
>
> v2.3→v2.4 变更(双 review 共识):**`ContextRestore` 简化 → `NativeResume`**(Phase 1 只做 native 路径,Phase 2/3 延后)· **B2 从 blocking 降级为 future capability** · **D3 退入 backlog** · **`engine_session_handle` key 修正**(`agent_uri`,非 `worker_uri`)· **handle 改为半透明 envelope**· **新增 §2.5 switch 操作序列与回滚** · **新增 §4.5 resume 失败 fallback** · **control_plane 拆为三轴**(`control_lifetime`/`surface`/`resume_backend`)· **curl 废弃单一 `stateless` 标签**.
> v2.3 变更:B3 关闭,选 (c):承认 reuse = 共享 runtime · D2 定义收紧 · 新增 D3(已退入 backlog).
> v2.2 变更:实测 `--session-id`/`--resume` 与 `server:esr-bridge` 无冲突 · 确立 cache/source-of-truth framing · control plane 分层 · config_dir 四分类厘清 · `ContextRestore` 三层封装契约(已简化) · 状态清单 17→16 位 · B1 关闭.

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

### ✅ 2.1a B1 已实测关闭 —— cc-PTY 的 state 在磁盘,不在进程

> **v2.1 曾断言**「PTY 是交互式 TUI,物理上无法喂历史 ⇒ Q1 对 cc-PTY 不可实施」。**这是错的。** Allen 纠正后实测推翻。

**实测(2026-07-10,隔离 `CLAUDE_CONFIG_DIR`,`--print` 非交互模式):**

| 步骤 | argv | 结果 |
|---|---|---|
| spawn | `--session-id <u1> --dangerously-skip-permissions` | ✅ |
| resume(**新进程**) | `--resume <u1>` | ✅ **答出上个进程的暗号** |
| spawn(**ezagent 完整 argv**) | `--session-id <u2> --dangerously-skip-permissions --dangerously-load-development-channels server:esr-bridge` | ✅ |
| resume(**新进程 + 完整 argv**) | `--resume <u2>` + 同上 | ✅ **答出暗号** |

**三条结论:**

1. **`--resume` 与 `server:esr-bridge` 开发通道无冲突**(该 flag 带值,argv 里零位置参数,追加 flag 安全)。
2. **state 的物理位置是磁盘**:`$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session-uuid>.jsonl`。**进程死掉,对话还在。** 这正是 Allen RULING 第②层原文所述(CLI-native resume restores same-backend conversation cache from disk)。
3. **cc 与 cc-headless 的 state 机制是同一个**(同一份 jsonl)。区别只在 control plane 形态,**不在 state 归属**。

**⇒ B1 从 `critical/不可实施` 降为 `low/两行 argv`**,实现照抄 cc-headless:

1. `spawn_plan.build_claude_cmd/3` argv 加 `--session-id <uuid>`;
2. uuid 持久化进 `:sandbox` slice 的 `respawn_template_data`(即 `cc_headless_agent.ex:92,106` 的 `claude_session_id`);
3. `ensure_subprocess_alive/2` 的 respawn argv 加 `--resume <同一 uuid>`。

**仍未验证**:PTY 交互模式未直接实测(用的是 `--print`,session 存储机制相同);MCP rebind 后 `AgentBridge.Registry` 能否重绑(状态位 13/14),需起真 ezagent;`--resume` 遇 config_dir 被 wipe(R2)必然失败,需 fallback 到 fresh。

### 2.1b 执行模型三轴(v2.4:原 `control_plane`/`surface` 两轴拆为三轴)

**决定 flavor 行为的不是"有没有 PTY",而是三个正交轴。**

v2.2/v2.3 的 `control_plane: :daemon | :in_process | :none` + `surface: :pty | :none` 混合了 MCP 位置、PTY 存在、runtime 生命周期。v2.4 拆为:

```
control_lifetime: :daemon | :embedded_live | :oneshot
surface:          :pty | :none
resume_backend:   :engine_handle | :message_store | :none
```

| 轴 | 含义 | 问的是 |
|---|---|---|
| `control_lifetime` | 控制面的存活形态 | 谁管进程生命周期?是否常驻? |
| `surface` | 是否有交互式终端 | 有没有 PTY TUI? |
| `resume_backend` | 同 backend 恢复走什么路径 | native resume 还是 PG replay? |

| flavor | control_lifetime | surface | resume_backend | 说明 |
|---|---|---|---|---|
| `codex` | `:daemon` | `:pty` | `:engine_handle` | app-server 常驻管理;PTY TUI resume 同一 thread |
| `codex-remote` | `:daemon` | `:none` | `:engine_handle` | 同上,无 PTY |
| `cc` | `:embedded_live` | `:pty` | `:engine_handle` | claude 进程内嵌 MCP;`--resume` 从磁盘 jsonl 恢复 |
| `cc-headless` | `:oneshot` | `:none` | `:engine_handle` | 每次 run 新建进程;同 `--resume` 机制 |
| `curl` | `:none` | `:none` | `:none` | 无子进程;conversation state 在 `:sandbox` slice |

> **v2.4 命名修正**:`cc` 的 control plane 原叫 `:in_process`(易误解为「在 BEAM 进程内」)。实为 `:embedded_live` —— 控制面(MCP server)嵌入 claude OS 进程,claude 进程常驻。`cc-headless` 原叫 `:none`,改为 `:oneshot` —— 每次 run 起新进程,不常驻。

**「PTY = disposable」对所有 flavor 成立,但恢复代价按 `resume_backend` 分层**:有 `:engine_handle` 的走 native resume(零 token);只有 `:message_store` 的走 PG replay。

> **这也修正了 §5.3 的建模轴**:`isolation` 的正确一级轴是 **`control_lifetime`**,不是"有无 PTY"。

### 2.2 fresh-spawn 全路径(不变,all-or-nothing)

```
resolve_cascade_content → instantiate_workers(原子 fresh?) → post_spawn_obligations(lineage+bind)
  → record_sandbox_state(:cast sandbox.update_config) → mount_behavior_overlay(folded)
  → AgentFlavorAttributes.put → join(role_name_conflict→grant_at_join→facet)
```
失败任一步 → `undo_fresh_workers` + cleanup + grant revoke(`template_spawn.ex:455,824`)。新实例侧回滚现成。

### 2.3 readiness:进程活着 ≠ ready

bridge join 才 ready(`transport_readiness.ex:56,88,168`),积压消息走 `PendingDelivery` drain。R3(重新武装)待补 `failed→not_ready` 回环。

### 2.4 「换 flavor = 换实例」的状态清单(**16 位**;v2:12 → v2.1:17 → v2.2:16)

> **codex review(high)**:v2 的"12 位"**遗漏了关键运行态**,不足以指导实现。下表补齐并标注 owner / 持久性 / key / switch 行为。
> **v2.2**:原 16/17 两位合并成一位 `engine_session_handle`(framework 收编)。

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
| **16** | **`engine_session_handle`**(v2.4 修正)<br>cc `--session-id <uuid>` · codex `thread_id` | **framework**(原:各 plugin 自管) | **agent-level durable state,key=`agent_uri`**(v2.4 修正:不在 `:sandbox` slice,避免 `worker_uri` 重启失效) | agent_uri | **同 engine → 保留**(native resume)<br>**跨 engine → 作废,走 replay** |

**关键点**:

- 第 13-16 位是 v2 遗漏的运行态。
- **v2.4 修正 handle 持久化 key**:v2.2/v2.3 将 handle 放在 `:sandbox` slice(其 key 为 `worker_uri`),但 worker 重启后 `worker_uri` 变化 → handle 丢失 → native resume 失效。**修正:handle 必须持久化在 agent-level durable state,key = `agent_uri`**(跨进程稳定)。若未来 D3 需要 per-session 隔离,再扩展为 `{agent_uri, session_uri}`。
- **它是 native resume 与 PG replay 的分岔点**:engine 不变则 handle 有效(命中缓存,零 token);engine 一变则 handle 作废(回源 PG)。**这正是 rehydration 只能靠 PG replay 的根因。**

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

## 4. Decision A 实质化:config_dir 四分类 + `ContextRestore` 契约

### 4.1 决策

- **上下文权威** = PG `MessageStore`(session 键,flavor-agnostic)
- **flavor** = 无状态执行器,每次 run 由上层喂完整 context
- **PTY 进程** = disposable,永非真相源(Q1 RULING)

### 4.2 `stateless ≠ diskless` — config_dir 四分类(v2.2 厘清:③是内容,④是指针)

| 类 | 内容 | 性质 | 恢复方式 |
|---|---|---|---|
| ① recipe-projected | skills(幂等拷贝 `orchestrator_bootstrap.ex:43,148`)、CLAUDE.md(由 recipe 写出 `home_runtime.ex:313-315`) | 纯函数投影,determinism 锚 `recipe/compose.ex:11-13`"同 recipe×任意 flavor→字节相同" | ✅ destroy-rebuild 可复现 |
| ② credential | `.credentials.json`(`cc_agent.ex:209`)、`auth.json` | cascade 可恢复 | ✅ restorable |
| **③ 对话内容本身** | `<uuid>.jsonl`(**实测**:`$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<uuid>.jsonl`)、codex `rollout-*.jsonl`(`codex_agent.ex:451`) | **缓存,不是权威** | **同 engine**:`--resume <handle>` 恢复(零 token)<br>**跨 engine**:作废 → 回源 PG replay |
| **④ handle(指向③的指针)** | `claude_session_id`(`cc_headless_agent.ex:92,106`)、codex `thread_id`(`codex_agent.ex:271,279`) | **control-plane 句柄** | v2.2 收编为 framework 管的 opaque `engine_session_handle`(§4.3) |

> ### v2.2 关键厘清:**③ 是内容,④ 是指向它的指针**
>
> v2.1 曾把 ③ 称作「唯一真不可复现的 state」。**实测推翻**:`<uuid>.jsonl` 在同 engine 下用 `--resume` 就能完整恢复(新进程答出了上个进程的暗号,§2.1a)。
>
> 正确表述:
> - **handle 有效**(同 engine)⇒ 命中缓存,零 token;
> - **handle 作废**(跨 engine)⇒ 回源 PG replay。
> - **①②③④ 没有一类是"权威"。权威只有 `MessageStore`。**
>
> 这就是 `ContextRestore.decide/3`(§4.3)的全部依据——**handle 是 native resume 与 PG replay 的分岔点**。

**Decision A 的"state"** 因此不再指某一类目录内容,而是指:**引擎侧的对话记忆(③)整体是可弃缓存;PG 是唯一 source of truth。** 第①/②类落盘不影响"无状态"定义(读者不能误读为"skills 落盘 = 有状态冲突")。

**这直接决定 §3 的两个操作**:switch(跨 engine)⇒ ④ 必然失效 ⇒ 必须 replay;reset(同 engine)⇒ ④ 有效 ⇒ 走 native resume。

### 4.3 `NativeResume` — 同 backend 恢复(v2.4 简化,原 `ContextRestore`)

**v2.4 核心修正**:v2.2/v2.3 的 `ContextRestore` 三层封装(L1 decide/rehydrate + L2 四个 callback + L3 core)是为 Step 2(`:replay`)预先设计的抽象。但 Step 1 实际只需两行 argv。**过早抽象会让代码看起来支持 replay,实际却是 `:not_implemented`。**

v2.4 采用渐进三阶段:

```
Phase 1: NativeResume(当前)
  只处理同 backend 恢复。输入 agent_uri + flavor + engine handle。
  输出 resume args / thread id。失败可 fallback。

Phase 2: ReplayRestore(未来,独立 SPEC)
  跨 backend,MessageStore 渲染,窗口策略,token budget,tool-result folding。

Phase 3: UnifiedContextRestore(未来)
  等 Phase 1 + 2 都成型后,收进统一 framework API。
```

**Phase 1 接口(最简)**:

```elixir
# 每个 flavor adapter 实现
@callback new_session_handle() :: engine_session_handle()
@callback resume_args(handle()) :: [String.t()]
```

**`engine_session_handle` 改为半透明 envelope**(v2.4 修正):

v2.2/v2.3 称 handle 为"opaque",但 framework 需要读 `engine_type`/`cwd`/`config_dir` 才能判断 native resume 是否可行。完全 opaque 与决策逻辑矛盾。

```elixir
# framework 读 envelope 做决策,adapter 只解释 handle_payload
%EngineSessionHandle{
  engine_type: :cc | :codex | :curl,
  handle_payload: opaque_adapter_payload,
  cwd: String.t(),
  config_dir: String.t(),
  version: 1
}
```

**resume 决策**(在调用点,不需要独立 `decide/3`):

```elixir
# 同 backend + 同 cwd → native resume
# 同 backend + cwd 变化 → handle 失效,退 fresh
# 跨 backend → future replay / fresh
case {old_engine, new_engine, same_cwd?} do
  {same, same, true}  -> :native
  {same, same, false} -> :fresh       # cwd 变了,handle 中的 cwd-slug 失效
  {_, _, _}           -> :fresh       # 跨 backend,replay 未实现
end
```

> **v2.4 废弃独立 `decide/3`/`rehydrate/3`**:三向分岔简单到不需要独立函数。等 Phase 3 再引入统一 API。

| 原问题 | 消解方式 |
|---|---|
| **B1** cc-PTY 恢复 | `new_session_handle/0` + `resume_args/1` ≈ 两行 |
| **第④类 metadata** | 散落 fs 文件 → `EngineSessionHandle` envelope,key=`agent_uri` |
| **状态清单 16/17 位** | 两位合并成一位 `engine_session_handle` |

### ⚠️ 4.4 B2 — 跨 backend replay(降级为 future capability)

**v2.4 降级**:v2.2/v2.3 标为「唯一真架构阻塞」,但跨 backend 无缝切换的真实需求未经验证。**同 backend native resume(进程挂了恢复、worker 重启不丢上下文)是高频需求;跨 backend 切换(cc→codex 无缝继续)是架构上应留口但不该支配当前设计。**

三个已知约束(留作 Phase 2 SPEC 输入):

1. **`render_context` 必须 per-flavor,cc-PTY 最难。** 跨 backend 时只能把历史**拼进第一条 prompt**,有损且吃 token。
2. **handle 隐含 cwd 依赖。** `$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<uuid>.jsonl` —— cwd 编码进路径。agent 换 worktree 则 handle 失效。Phase 1 `EngineSessionHandle` envelope 已捕获 cwd,可提前检测。
3. **replay 的幂等与预算**:历史 tool call 不能重执行 → tool result 折叠成文本;需窗口策略(最近 N 条 / token budget / 摘要)。

### 4.5 resume 失败 fallback(v2.4 新增)

**v2.2/v2.3 只承认 `--resume` 遇 config_dir 被 wipe 必然失败,但未定义失败后行为。v2.4 定义为一等路径:**

```
try native resume(same backend, handle valid)
  success → continue(normal path)
  failure → mark handle invalid(in envelope)
            emit system event(:engine_cache_lost)
            fallback:
              if replay implemented(Phase 2) → replay from MessageStore
              else → fresh spawn WITH user-visible warning
```

**关键:不能 silent fresh spawn。** 用户需要知道「旧 engine cache 丢了(config_dir 被清理/磁盘满/cwd 变化),已开新 runtime」。

### 4.6 switch 操作序列与回滚(v2.4 新增)

**v2.2/v2.3 的 16 位状态清单只描述每位 switch 行为,未定义顺序、原子边界、失败回滚。v2.4 补序列:**

```
 1. prepare new instance      —— resolve recipe × new_flavor
 2. spawn new runtime         —— spawn sidecar / create config_dir
 3. mount behavior overlay    —— mount flavor-specific behaviors
 4. grant credentials         —— credential cascade for new instance
 5. wait ready                —— bridge join, ReadyGate open
 6. PAUSE delivery            —— buffer incoming messages(PendingDelivery)
 7. atomic membership cutover —— leave old role → join new role(同 role_name)
 8. grant member-cap          —— grant session-scoped cap for new member
 9. DRAIN pending delivery    —— deliver buffered messages to new instance
10. retire old runtime        —— SIGTERM old sidecar, cleanup old sandbox
```

| 步骤 | 失败补偿 |
|---|---|
| 1-5 | 任一失败 → `undo_fresh_workers`(已有),旧实例不受影响 |
| 6 | pause 本身无副作用;失败重试 |
| 7 | **原子边界**:leave 成功 + join 失败 → **re-join 旧实例**(补偿:走旧 agent_uri 的 `add_participant`)。join 成功 + leave 失败 → 两条 membership 共存 → 后台清理 + alert |
| 8 | grant 失败 → revoke 步骤 7 的 membership → 恢复旧成员状态 |
| 9 | drain 超时 → DLQ(已有),消息不丢 |
| 10 | SIGTERM 失败 → force kill + mark zombie(已有 `ensure_subprocess_alive` 自愈) |

**核心原则:先建新的、全 ready、再切指针、最后清旧的。** 建新过程失败 → 旧的不动。切指针失败 → 补偿回到旧状态。旧的收尾失败 → 已有自愈机制。

> **v2.4 简化:跨 backend switch 当前不支持(Phase 1)**。上述序列为同 backend switch 设计;跨 backend 时步骤 2(spawn)和步骤 5(wait ready)需额外处理,等 Phase 2。

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

### 5.3 隔离能力位(⚠️ **提案,未落代码;建模轴见 §2.1b**)

> **codex review(high)**:`AgentFlavorRegistry.decl` 当前只有 `kind/template_class/instance_behaviors/cap_policy`(`agent_flavor_registry.ex:49`),**无 `isolation` 字段**;bridge 层只有 `:subprocess_ws | :in_process_sync` 两档 transport class(`adapter_registry.ex:116`)。**本节是 schema 提案**。
>
> **v2.4 修正**:Step 1(Phase 1 NativeResume)落 `engine_session_handle` 后**不关闭 B4**。handle 的有无不能表达 per-instance / per-thread / in-process-sync / reuse 安全 / runtime 共享等完整语义。B4 的真正关闭条件 = `AgentFlavorRegistry` 有明确的 isolation schema,且 switch/reuse 用它做 enforcement。
>
> **建模轴**:一级轴为 **`control_lifetime`**(§2.1b 三轴),不是"有无 PTY"。

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

### ✅ 5.5 B3 已裁决(2026-07-10):承认 reuse = 共享 runtime

**选 (c)**。三条出路中选了最诚实的:承认 reuse 就是共享同一个 live worker,不强行承诺「独立可写 runtime」。

**裁决理由**:
- config_dir / `CODEX_HOME` 是 `agent_uri` 的纯函数(`config_dir.ex:48`;`home_runtime.ex:90`),同 `agent_uri` 跨两 session ⇒ 天然同一 config_dir、同一 live worker。代码现状如此,没必要用措辞掩盖。
- Part C admission gate(#1269)已兜底:**非 owner 的 reuse join 被 PEND**(无 member-cap、花不了凭据),owner 自己 reuse 时上下文相通是可接受的 trade-off。
- Allen Q2 反问「贡献身份的同时共享记忆好像也挺好的吧」——**共享记忆本身不是问题,问题是谁能访问**。admission gate 解决了后者。
- 「独立可写 runtime」列为 **D3 未来设计**,不阻塞当前 Step 1。

**D2 定义收紧为**:

> 共享身份 + 只读凭据 + **共享 runtime**(同 agent_uri、同 config_dir、同 live worker)。跨 session 上下文相通;非 owner 经 admission gate PEND 保护。

**D3(backlog,不阻塞当前 Phase)**:

> 「共享身份但不共享记忆」—— 同一 agent identity 跨 session 复用,但每 session 独立 context window。需要 per-session runtime key(`{agent_uri, session_uri}`)或等效隔离机制。
>
> **v2.4 退入 backlog**:当前 fresh spawn(同 recipe、不同实例)已覆盖「独立记忆」需求。D3 无真实用例驱动,不阻塞 Phase 1/2。等有明确产品场景时再设计。

**对 Phase 1 的影响**:无。Phase 1(NativeResume)不涉及 reuse 路径,`engine_session_handle` 只管 native resume。B3 不再阻塞。`

---

- **D2(默认,安全)** — 共享身份 + **只读**凭据 + **共享 runtime**(同 agent_uri、同 config_dir、同 live worker,§5.5 裁决)。
  - 跨 session 上下文相通。非 owner 经 **Part C admission gate** 保护(`admission_pending?/2`):非 owner 且非 manages 的凭据型成员被 **PEND**,无 member-cap、花不了凭据,直到 owner `:approve_admission`。
  - D2 不是"共享 config"(config_dir 是 `agent_uri` 纯函数 `home_runtime.ex:90`,共享 path = 写竞争+串台,曾被 `session_discriminator`(`entity/agent.ex:373,434`)修复)——当前实现就是共享 runtime,诚实承认。
- **D1(省资源)** — 共享执行器,仅对 `:per_thread`/`:stateless` flavor 允许。需 per-run session scope + 串行化(cc-headless)或 per-session thread(codex-remote)。
- **D3(未来设计,见 §5.5)** — 「共享身份但不共享记忆」:同一 agent identity 跨 session 复用,但每 session 独立 context window。需 per-session runtime key(`{agent_uri, session_uri}`)或等效隔离机制。不阻塞当前 Step 1。

---

## 6. 存储分层:PG(权威)vs fs(缓存/导出)

### 6.1 现状

- **PG · event-sourcing 骨架**:`EventLog`(invocations)→ `SnapshotStore`(每 100 events)→ `MessageStore`(**每 session 一 row,copy+ref model**;`message_store.ex:80-81`)。

> **纠错(v2.1)**:v2 写 `messages + message_routings` join 表,那是 `message_store.ex:18-25` 的 **stale moduledoc**。代码 `:80-81` 明写「vestigial `message_routings` multi-routing **was removed** —— 跨 session 转发是**复制一条新 message** 进目标 session(copy+ref model)」;`in_session_since/2`(`:123`)直接按 `m.session_uri` 查,**无 JOIN**。→ §6.2「一条消息挂多 session」那行的论据随之作废(现在是复制,不是共享行)。
- **文件系统 · config_dir(四分类,全是缓存)**:① recipe 投影(可复现)· ② 凭据(cascade 可恢复)· ③ 对话内容 `<uuid>.jsonl`(同 engine 可 `--resume`)· ④ handle(指向③的指针)。**没有一类是"权威"** —— 权威只有 `MessageStore`(§4.2)。

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

### 7.1 v2.4:废弃单一 `stateless` 标签

v2.1 曾称 curl 为 `:stateless`,后纠正为「stateless transport + stateful flavor behavior」。但`stateless` 这个标签仍混乱——无进程?无 config_dir?无 conversation?无 engine handle? 四件事混在一个词里。

**v2.4 拆为三轴**(与 §2.1b 一致):

| 轴 | curl 的值 | 含义 |
|---|---|---|
| `process_lifecycle` | `:none` | 无子进程,无 PTY |
| `transport_state` | `:stateless` | 每次 call 无连接状态 |
| `conversation_state` | `:sandbox_slice` | durable conversation/last_error/last_tokens 在 `:curl_agent` slice |

> curl 的 conversation state 存在 PG(through behavior slice snapshot)——它实际上是**最"权威"的 flavor 状态**(在同一个 PG 里),与其他 flavor 的「引擎本地缓存」性质不同。`stateless` 这个词掩盖了这个差异。

### 7.2 生命周期退化

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

### 8.2 实施阻塞项(v2.4 双 review 后更新)

| # | 阻塞项 | 严重性 | 状态 |
|---|---|---|---|
| ~~B1~~ | ~~Q1 对 cc-PTY 不可实施~~ | ~~critical~~ → **low** | ✅ **实测关闭**(§2.1a):`--resume` 可用。Phase 1 实现 = 两行 argv + handle 持久化 |
| **B2** | **跨 backend replay 的渲染契约** —— 仅跨 backend 需要。三个约束:per-flavor 渲染· cwd 依赖 · 幂等与 token budget | ~~critical~~ → **future** | 🟡 **降级为 future capability**(§4.4):Phase 2 独立 SPEC 排期,**不阻塞 Phase 1** |
| ~~B3~~ | ~~D2 runtime key 矛盾~~ | resolved | ✅ **已裁决(c)**(§5.5):承认 reuse = 共享 runtime |
| **B4** | `isolation` 能力位未建模 —— `AgentFlavorRegistry.decl` 无此字段 | **high** | 🟠 **Phase 1 不关闭 B4**(§5.3)。建模轴已找到(`control_lifetime`/`surface`/`resume_backend`)。B4 关闭条件 = `AgentFlavorRegistry` 完整 isolation schema |
| ~~B5~~ | ~~curl 不是 `:stateless`~~ | ~~high~~ | ✅ 已修(§7):废弃单一 `stateless` 标签,拆为三轴 |

### 8.3 已修正的事实错误

**v2.3 → v2.4**(双 review 共识):
- **`ContextRestore` 简化 → `NativeResume`**:Phase 1 只做 native 路径(`new_session_handle/0` + `resume_args/1`),Phase 2(ReplayRestore)/Phase 3(UnifiedContextRestore)延后。
- **B2 降级**:从「唯一真架构阻塞」→「future capability」。同 backend native resume 是高频需求;跨 backend switch 未经验证。
- **D3 退入 backlog**:fresh spawn 已覆盖「独立记忆」需求。不阻塞 Phase 1/2。
- **`engine_session_handle` key 修正**:`worker_uri`(sandbox slice)→ `agent_uri`(agent-level durable state),避免 worker 重启后 handle 丢失。
- **handle 改为半透明 envelope**:`%EngineSessionHandle{engine_type, handle_payload, cwd, config_dir, version}`。framework 读 envelope 做决策,adapter 只解释 payload。
- **control_plane 拆为三轴**:`control_lifetime`/`surface`/`resume_backend`(原 `:in_process`/`:none` 命名混淆)。
- **新增 §4.5 resume 失败 fallback**:native resume 失败 → invalidate handle → emit system event → fresh spawn with user-visible warning。
- **新增 §4.6 switch 操作序列与回滚**:10 步序列,带每步失败补偿。
- **curl 废弃单一 `stateless` 标签**:拆为 `process_lifecycle`/`transport_state`/`conversation_state` 三轴。
- **Step 1 ≠ B4 关闭**:handle 的有无不能替代完整 isolation schema。

**v2.2 → v2.3**(B3 裁决):
- B3 关闭,选 (c):承认 reuse = 共享 runtime。
- D2 定义收紧。新增 D3(已退入 backlog)。

**v2 → v2.1**:`message_routings` 已移除(copy+ref model)· URI 格式 `entity://<ws>/agent/<name>` · config_dir 补第④类 · 状态清单 12 位 → 17 位。

**v2.1 → v2.2**(实测推翻三条):
- "PTY 物理上无法喂历史"是错的 —— `--resume` 实测可恢复。
- "PTY 是一个 mode"是错的 —— PTY 是正交 surface。
- "第③类是唯一真不可复现的 state"是错的 —— ③是内容,④是指针;权威只有 MessageStore。

> **本稿是 decision record,不是 implementation spec。**
> **Phase 1(NativeResume)落地后即可进入实施**;B2(跨 backend replay)降级为 future capability,独立 SPEC 排期;B3 已裁决(c);B4 待 isolation schema 建模。

---

## 9. 分期交付(v2.4:Phase 1/2/3)

```
Phase 1: NativeResume(当前,可立即做)
  同 backend 恢复:engine_session_handle + new_session_handle/0 + resume_args/1
  cc 补两行 argv,codex 把 thread_id 挪进 handle
  收益:B1 关闭 · 第④类收编 · 状态位合并 · resume 失败有 fallback
  不阻塞:B4(isolation schema 待独立建模,§5.3)

Phase 2: ReplayRestore(未来,独立 SPEC)
  跨 backend:MessageStore → backend prompt/messages
  render_context + 窗口策略 + token budget + tool-result folding + 幂等
  = B2 本体

Phase 3: UnifiedContextRestore(未来)
  等 Phase 1+2 成型后,收进统一 framework API
```

**Phase 1 落地后,本稿即可进入实施。** Phase 2 作为独立 SPEC 排期;B4 待 `AgentFlavorRegistry` isolation schema 建模;D3 退入 backlog。S2(内容迁移)/S3(多 member)/curl 统一(退化)已收口;app.ex dead-code drift 登记清理。

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
