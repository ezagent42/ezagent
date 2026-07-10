# Allen PR #1256 评审:解读 · 分析 · 行动计划

日期:2026-07-09 · 关联 [PR #1256](https://github.com/ezagent42/ezagent/pull/1256) · Allen 评审 4 条(2026-07-08)
基线:Allen 现读 @ `pr1256`(= `b260b09aa`,已确认是 `origin/main` 祖先);本文件所引 `file:line` 沿用其评审,**动手项需二次坐实**。

> 用途:把 Allen 回复拆成「文档改进(A)」与「要动手(B)」两类可认领单元,方便并行、认领、review。**这是工作分解,不是最终设计** —— 设计结论待 v2 稿 + grill。

---

## 0. 一句话

四个待决问方向 Allen **全部确认**,但各收紧成「定理」;真正的增量在:一个**方向反转(Q1 RULING)**、两个**超出文档的行动项**(reuse 授权洞 + hello viewer 疑似生产 bug)、对 Decision A 的两处**概念精修**(`stateless≠diskless` 三分类 + rehydration 契约升必答)。

---

## 1. Allen 评审时间线(演进式,后条 supersede 前条)

| # | 时间(UTC) | 主题 | 关键动作 |
|---|---|---|---|
| 1 | 07-08 14:52 | Pre-grill:Q1–Q4 + Decision A 三分类 + provenance | 四问各给判别 file:line;初判 Q1「排除 PTY」 |
| 2 | 07-08 15:34 | Q3 addendum(N viewers 场景) | role-vs-group 三层;提「audience selector」 |
| 3 | 07-08 15:39 | Q3 REVISION(查 live manifest) | 改为 **per-role cardinality**;抛出 hello viewer ⚠️ 验证项 |
| 4 | 07-08 15:50 | **Q1 RULING**(推翻自己) | **全 flavor(含 PTY)一律无状态;进程死=NORMAL case** |

---

## 2. 逐条解读 + 我的分析

### Q1 —— 反转:全 flavor 无状态,进程死是常态(RULING 为准)

- **Allen 结论**(15:50):cc/codex 含 PTY **一律当无状态执行器**。理由:网络/节点 churn 随时弄挂 PTY,重启即失忆已是运营现实 → 进程死必须当 NORMAL case。三层 state 归属:
  1. 对话上下文 → **PG `MessageStore`**(上层,backend-agnostic,可 replay)
  2. workspace/folder → **recipe 引用的 durable dir**(进程死了还在;同 backend `claude --continue` 从磁盘恢复 cache)
  3. PTY 进程 → **disposable,永非真相源**
- **跨 backend caveat**:folder 保留但 CLI transcript 格式不同 → 对话连续性只能靠 (1) PG replay → **rehydration 契约是 Decision A 必答项,不是 open question**。
- **我的分析**:这是把 Decision A 推到极致并统一,不是推翻。**作废我们 v1.1 的「cc-PTY 留 stateful 特例」提法**。状态机要按「进程随时死」重设计(与已有 R1 原地重启 / `ensure_subprocess_alive` self-heal 一致,只是从"异常恢复"升为"正常路径")。→ 见 **DOC-Q1**。

### Q2 —— 确认 D2,但挖出真安全洞

- **Allen 结论**:默认 D2 正确,但定义收紧为「共享身份 + **只读**凭据 + **每 session 独立可写 runtime**」(不是「共享 config」—— config_dir 是 `agent_uri` 纯函数 `home_runtime.ex:90`,共享 path 会写竞争)。D1 会复活 `session_discriminator`(`entity/agent.ex:373,434`)当初消灭的串台事故。
- **附加发现(他明说"更该先修")**:reuse join 的 `provision_invited_join_authority/3`(`membership.ex:751`)丢弃 inviter、joiner 非 user URI 时落 `else -> :ok`(`:764-766`),reuse 侧唯一门是 recipe 名相等(`definition_agents.ex:248`)——**缺 operator→agent 授权校验**,可跨用户 join 别人 agent(连带 CODEX_HOME 凭据)。#161 形状在 reuse 侧重现。
- **我的分析**:这是**行动项不是文档条目**,一个真实越权/凭据串台漏洞 → **ACT-2 开 issue**。文档只记「reuse 需补 operator→agent 授权门」硬约束(DOC-Q2)。

### Q3 —— 落到 per-role cardinality + 一个疑似生产 bug

- **Allen 结论**(15:39 为准):**occupancy 是 per-role policy,不是全局不变式**。role 默认 `cardinality: one`(accountable 单持有者);可声明 `cardinality: many`(如 viewer,`{:role}` fan-out 到所有 edge)。S3 换实例跟 cardinality 正交,仍走 **handoff/cutover**。真·群组扇出的现成原语是 **Legend + `$session_members`**(`legend.ex:1,7`),不是重载 role_name。
- **⚠️ 他点名要验证的疑似生产 bug**:唯一性 guard(`members.ex:67-69`)join 时拒同名,但 hello 声明了本应 N 人的 human viewer role(`role_name: viewer, fill: human` + `from_role: viewer` 路由)。**2nd+ 匿名 viewer 现在怎么共存?** 要么 join 不带 viewer edge(则 `from_role: viewer` 只匹配第一个访客 = 官网潜在路由 bug),要么 human join 绕过 guard。"**请今天具体验证,可能是独立于设计的真实缺陷**"。
- **我的分析**:设计侧清晰(per-role cardinality),但先要**动手验证现状**(ACT-1),验证结论直接喂给 DOC-Q3(cardinality 设计要基于真实占用现状)。

### Q4 —— 统一(退化生命周期)+ 一根正交轴

- **Allen 结论**:curl 声明 `:stateless` + `:in_process_sync`,ready=恒真 / fail=数据 / reset=清 slice / switch=repoint config —— **同一套能力位接口,hook 退化**,不分叉。更深一点:**completion vs tool-loop 与 flavor 正交**(curl 纯 completion `bridge_adapter.ex:105`;tool-loop 只在 cc 的 MCP orchestrator `mcp_server.ex:329`)。真做 tool-loop 应在 flavor **之上**起共享轴。
- **我的分析**:与 v1.1 隔离能力位接口一致,直接接受。补一句正交轴,保护「flavor = 可互换 completion backend」不变式(`recipe/compose.ex:11-13`)。→ DOC-Q4。

### Decision A 精修 —— `stateless ≠ diskless`,config_dir 三分类

- **Allen 结论**:Decision A 的「state」要精确收窄到第 3 类。config_dir 三分类:
  1. **recipe 投影**(skills 幂等拷贝 `orchestrator_bootstrap.ex:43,148`;CLAUDE.md 由 recipe 写出 `home_runtime.ex:313-315`;determinism 锚 `recipe/compose.ex:11-13`)—— 纯函数投影,destroy-rebuild 可复现,**与无状态完全相容**。
  2. **凭据**(`.credentials.json` `cc_agent.ex:209` / `CODEX_HOME/auth.json`)—— cascade 可恢复。
  3. **runtime 累积**(CLI 对话记忆 / codex `rollout-*.jsonl` `codex_agent.ex:451`)—— **唯一真不可复现**,即 Q1 的 PTY statefulness 换马甲。
- **我的分析**:必须吸收。v1.1 §4.1/§6.1 笼统说「config_dir 降缓存」会误伤 skills(可复现投影,不是 state),读者误读成「skills 落盘 vs 无状态冲突」。改法:明写 `stateless≠diskless`,state 特指第 3 类,给第 3 类 rehydration 契约(与 Q1 RULING 收敛:PG replay,不排除 PTY)。→ DOC-A。

### Provenance 提醒

- `SkillRegistry` 内容寻址强化(SHA-256 dir-hash)**只并了 SPEC、代码未上 main**(在 `feat/skill-dist-p1`);第 1 类引的是 pr1256 已有的幂等拷贝。文档若引 SkillRegistry 要注明未合并。→ DOC-prov(一句注脚)。

---

## 3. 行动分解(可认领 · 可并行)

### A 类 — 文档改进(v1.1 → v2,不动代码)

| ID | 小节 | 内容 | 依赖 | 可并行 |
|---|---|---|---|---|
| DOC-Q1 | §4.4/§4.5/§2 | 删「PTY stateful 特例」;全 flavor disposable executor + 进程死=normal + state 三层 + 状态机按 process-death 重设计 | 与 DOC-A 耦合 | 与 DOC-Q2/Q3/Q4 |
| DOC-A | §4.1/§6 | config_dir 三分类 + `stateless≠diskless` + **rehydration 契约(跨 backend 靠 PG replay)升为必答** | 与 DOC-Q1 耦合 | 同上 |
| DOC-Q2 | §5.3 | D2 收紧定义(共享身份+只读凭据+独立可写 runtime)+ 记「reuse 授权门」硬约束 | — | ✅ |
| DOC-Q3 | §5.2/新节 | per-role cardinality(one/many)+ S3=handoff/cutover + Legend/`$session_members` 备注 | **依赖 ACT-1 结论** | 起草可并行,定稿等 ACT-1 |
| DOC-Q4 | §5/§6 | curl 退化生命周期 + completion/tool-loop 正交轴 | — | ✅(体量小) |
| DOC-prov | 脚注 | SkillRegistry 未上 main 注明 | — | ✅ |

> 建议 DOC-Q1 + DOC-A 由**同一人**做(都关于 state 归属/rehydration,强耦合)。

### B 类 — 要动手(独立于文档)

| ID | 类型 | 内容 | 依赖 | 产出 |
|---|---|---|---|---|
| ACT-1 | 🟠 验证 | hello viewer role N-occupant 现状:查 hello manifest + `do_join`/`role_name_conflict`(`members.ex:67-69`)+ `from_role: viewer` 路由,判定「绕过 guard」vs「只匹配第一访客(路由 bug)」 | — | 结论 + 若是 bug 开 issue |
| ACT-2 | 🔴 安全 | reuse 缺 operator→agent 授权门(`membership.ex:751-766`),#161 形状重现 | — | 开 issue(不在本 PR 修) |

---

## 4. 执行顺序(我的建议)

1. ✅ **ACT-1**(hello viewer 验证 + 6.3 访客消息路径 + 6.4 dead-code drift)—— **done**(§6 完整结论)。
2. ✅ **ACT-2** 安全 issue —— **作废**(#1269 false-positive,Part C admission gate 兜底)。
3. ✅ ACT-1 + 6.3 + 6.4 出结论 → **DOC-Q3** 定稿(cardinality 吸收现状,见 §6.5)。
4. **DOC-Q1 + DOC-A**(state/rehydration 核心,一起做) —— 下一步。
5. 汇总成 **v2** → 更新 PR #1256 描述 + Artifact 图。
6. 🆕 **drift 清理** —— `app.ex` dead code(l line ~131-136)登记待清(issue / #1255 附加项,§6.4)。

### 并行认领建议(若多人)

- **甲**:ACT-1 → DOC-Q3(验证→设计连贯)
- **乙**:ACT-2 安全 issue → DOC-Q2
- **丙**:DOC-Q1 + DOC-A(state 归属核心)
- DOC-Q4 / DOC-prov:体量小,穿插认领

---

## 5. 待 grill 收敛的 open items

- rehydration 契约的**具体形态**(PG replay 如何喂回 headless/PTY;跨 backend 的 transcript 重建粒度)。
- per-role `cardinality: many` 的**路由实现**(`role_name_to_uri`/`expand_receiver` 从首命中→集合 + Delivery fan-out)是否本期做,还是先只做 handoff。
- D2「独立可写 runtime」与 reuse「同 `agent_uri`」的**张力**:reuse 若要独立可写 runtime,是否意味着 reuse 也要 per-session 目录(与「复用同一 agent_uri」矛盾)—— 需 Allen 定。

---

## 6. ACT-1 验证结论(2026-07-09,codex 二次验证后**修正**)

> ⚠️ 本节第一版结论有**实质错误**(读错了源文件),经 codex 独立交叉验证纠正。保留修正过程。**方法教训**:socialware Definition 现读要认 deploy-seed `manifest.yaml`,不是插件里的旧硬编码。

### 6.1 修正:Allen 的前提**成立**(我第一版读错源)

hello 的**当前生效 Definition 是** deploy-seed 的 `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`,**不是** `app.ex` 的硬编码 roles(front-desk/builder/concierge/llm —— **过时死路径**,git log 印证 hello 已于 #1233 迁部署级 seed 车道)。`Demo.Hello` moduledoc 权威声明:生产与测试都经 deploy-seed lane、`manifest.yaml`「is the one source of truth」、旧 boot publish 已删(`hello.ex:5-24`)。

manifest.yaml 里 **Allen 的前提成立**:
- roles 含 **`role_name: viewer, fill: human`**(`manifest.yaml:27-28`)+ builder/responser 两个 agent(recipe `np`/flavor `py`,`:19-26`)。
- routing_rules 含 **`from_role: viewer → responser`**(`manifest.yaml:29-36`)+ `from_role: responser AND text_matches ^\[need-build\] → builder`(`:37-47`)。

**→ 我第一版「hello 无 viewer role」是错的**,读了过时的 `app.ex:131-136`。codex 找到真源。

### 6.2 但 Allen 的具体推论(唯一性冲突 / 只路由第一个)**仍不成立**(第一版与 codex 一致)

- 匿名访客走 `AnonAdmission.admit_anonymous_participant` → `dispatch_join`,**只传 `%{member: anon_uri}`、不带 role_name**(`anon_admission.ex:100-107`)→ role_name facet = nil。
- `role_name_conflict(_, _, nil) → :ok`(`members.ex:67`)→ **多个匿名访客天然共存,不撞唯一性 guard**。
- `from_role: viewer` 按**发消息者在 members snapshot 的 role_name facet** 匹配(`matcher.ex:178-179,322-326`),不是按 Definition 声明自动套到匿名访客;匿名不带 facet → 既不抢占 viewer、也不会「只命中第一个」。

### 6.3 ⚠️ 但暴露一个可能更真实的问题(待查,**非 Allen 所指的那个**)

匿名访客既然**不带 `viewer` role_name facet**,那 `from_role: viewer → responser` 规则对**匿名访客发的消息永远不匹配**——访客消息不经这条规则到 responser。hello 官网访客若能对话,要么有别的兜底(如 `requires: orchestrator`,`manifest.yaml:7-8`,orchestrator fan-out),要么这是个 routing gap。**这才是「官网潜在问题」的真实候选形态**(访客→responser 直路由空转),需查实访客消息实际怎么到 agent。

### 6.4 净结论

- Allen 前提(viewer/human role + `from_role:viewer`)**成立**;其推导的**唯一性冲突 / 只路由第一个 bug 不成立**(匿名不占 role_name)。
### 6.3 空转查实 — `from_role: viewer` 不 fire,但消息走 `$session_members` 兜底(非空转)

现读 `handle_send`(`session.ex:540`)→ `Resolver.resolve_with_ctx`(:612-635),消息路由分两层:

1. **manifest 声明的规则**(`from_role: viewer → responser`):`match?`(`matcher.ex:178-179`)读取 **sender 在 members snapshot 的 `role_name` facet**;匿名访客无 facet → **永不 fire**(codex 与我一致)。
2. **框架 `system_default` 规则** `receivers: ["$session_members"]`(`resolver.ex:17-25`):"the unconditional broadcast token"——**每一条消息的默认兜底**,展开为**所有 session 成员**(排除 sender)。**访客消息走这条广播到所有 agent(含 responser/builder)。**

**结论**:`from_role: viewer` 规则对匿名访客**空转**(无实际作用),但**消息可靠到达 agent**(通过 `$session_members` 系统默认)。**不是 delivery gap,是规则冗余**:`from_role: viewer` 的设计意图(区分 viewer 发件人)与当前匿名访客的"不占 role_name"机制不匹配——它需要一个真正带 `role_name: viewer` 的 human 发件人才会 fire。

> **侧记**:若未来 Q3 `cardinality: many` 让匿名访客落在 viewer role 下,`from_role: viewer` 就能 fire → 访客→responser 直路由生效,`$session_members` 广播退为兜底。

### 6.4 死代码 drift — `app.ex` 旧硬编码 vs `manifest.yaml` 现行源

- **`manifest.yaml` 是权威源**:`application.ex:46-54` 显式声明 hello 走 deploy-seed package(`apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`),旧 `App.ensure_app` boot publish 及 `Demo.Hello.publish/0` **均已删除**(`hello.ex:14-18`)。
- **`app.ex:131-136` 的 roles(front-desk / builder / concierge / llm,全 agent)是死代码**:与 manifest.yaml 的 roles(builder / responser / viewer)不一致,**没有 runtime caller 走这条路径**。git log 印证 hello 已于 #1233 迁部署级 seed 车道。
- **登记录入**:app.ex 过时文件 → 待清理(提 issue 或并入 #1255 命名清理的附加项)。

### 6.5 净结论

### 6.5 对 DOC-Q3 的影响(更新)

per-role cardinality(`one|many`)从「前瞻设计」升为**有真实锚点**:manifest 已把 viewer 声明成 role,Q3 的 `cardinality: many` 正是给它一个正式的多占用语义(而非靠「anon 不占 role_name」的隐式绕过)。DOC-Q3 应据此写:viewer 的多占用当前是**隐式**(anon 无 role_name)、Q3 使其**显式**(role + cardinality:many + `{:role}` fan-out),并连带解决 6.3 的空转(让匿名访客真正落在 viewer role 下)。

---

## 7. 2026-07-09 plan 同步(main `plan.md` #1265/#1268 + #1269 rebase 后)

### 7.1 当前这块在今日 plan 的定位

团队本日头号 = 跑通自举 dev loop(Track C);**「当前这块」= plan §3/§7 里 `gagameow` 行的第 2 项「续 #1256 设计」**,不是头号 Track C。当前 session 今日安排:

- 吸收 Allen **Q1 裁定**:**PTY 也是无状态执行器**(状态在 recipe 引用的 folder;对话上下文 = PG 回放)——与昨日 §2 Q1 RULING 一致,今日随 plan 落定。
- **Q3 基数 `one|many` 今日 ratify**(plan §1 5 分钟项:"viewer 角色基数方向批准…Allen 昨晚倾向 yes,今日 ratify")。
- **viewer 唯一性结论**(= ACT-1,已做,§6:无 bug)。
- **DoD(plan 明文)**:「#1256 更新含 Q1/Q3 裁定 + viewer 唯一性结论」→ 即把设计稿推进到 **v2**。

### 7.2 两块任务区分(均在 `gagameow` 名下,分属不同 session)

| 块 | 内容 | 归属 session |
|---|---|---|
| **当前这块** | 续 #1256 设计(Q1/Q3 裁定 + viewer 结论 → v2) | **本 session** |
| 另一块 | **Track C**:自创建 socialware 编写/安装失败修复 + @mention 派发 `:unauthorized`(ezagent in ezagent 自举测试) | 其他 session |
| 横切(偏另一块) | **Track A**:产品内 agent 必须拿显式 worktree,绝不落 main checkout | 其他 session / 工程纪律 |

### 7.3 对 §3 行动分解的调整

| 原项 | 调整 | 依据 |
|---|---|---|
| ACT-1 viewer 验证 | ✅ 完成,无 bug(§6) | 对应 plan viewer 任务 |
| **ACT-2 reuse 授权洞** | ❌ **作废(FALSE POSITIVE)** | #1269:Part C admission gate 兜底(pend/approve)、三测试绿、仅加文档;且 owner=coordinator 非你 |
| DOC-prov(SkillRegistry 注脚) | ❌ **删** | #1266 SkillRegistry P1-P3 已上 main |
| DOC-Q1 + DOC-A | ✅ 方向 ratify → 落地;**rehydration(跨 backend PG 回放)升为必答** | Allen Q1 裁定(plan 明文) |
| DOC-Q3 | ✅ **今日 ratify(one\|many)** → 落地,吸收 ACT-1(前瞻设计,非修 bug) | plan §1 |
| DOC-Q2 | ⚠️ **删「reuse 授权门」条**;D2 收紧定义保留,改引 Part C pend/approve 兜底 | #1269 |
| DOC-Q4 | 不变 | — |
| **新增 DOC-名对齐** | 对齐 **Decision #161 四层词汇**(Definition/Recipe/Manifest/Registry,#1253)、`RecipeResolver` 重命名(#1261)、`Ezagent.Agent.Recipe*` 点约定 + arch gate(#1255) | rebase 新增 |

### 7.4 净结果

- **当前 session 今日交付** = #1256 设计稿 **v1.1 → v2**:并入 Q1(PTY 无状态)+ Q3(基数 `one|many`)+ viewer 结论(§6)+ rehydration 契约 + 命名/词汇对齐;删 provenance 注脚、reuse 授权门条。
- **ACT-2 / Track C / Track A 不在本 session** —— ACT-2 已作废,后两者归其他 session。
- 待办的 B 类动手项已清零(ACT-1 done、ACT-2 作废),本 session 只剩 **A 类文档(v2)**。
