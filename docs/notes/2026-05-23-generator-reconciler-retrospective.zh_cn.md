# Generator → Reconciler 复盘 — *学到了什么:错误的抽象*

> **日期**: 2026-05-23。作者: Claude,按 Allen 飞书 2026-05-23 指示。
> **相关文档**:
> - SPEC: `docs/superpowers/specs/2026-05-23-generator-reconciler.md`
> - PR-A (#259, commit `350e9c3`) — Session.spawn_from_template/2 reconciler 化
> - PR-C (#260, commit `526c401`) — update_agent_template / add / remove reconciler 化
> - 被取代的设计: `docs/superpowers/specs/2026-05-22-phase-7-completion.md`
>   §"Spawn phase" + §1.6/§1.6a (cleanup_partial saga)
> - 触发这一切的审计:
>   `docs/notes/phase-7-implementation-audit-2026-05-22.md`

这是一份**复盘**:Phase-7-completion 的 Generator 以 saga-cleanup 模型
上线,经过 10 轮 codex 对抗审计仍无法收敛到 0 个 HIGH 发现,最终被
reconciler 重构溶解,删除约 800 LOC。语气**诚实** — *codex 迭代是有
价值的;教训在于抽象选择,不在于工程实现*。文末附编号 LESSONS,供
将来的开发者参考。

---

## §1 模式 — atomic-saga 语义,枚举式 cleanup

Phase-7-completion 的 PR-4 (Generator —
`Session.spawn_from_template/2`) 和 PR-5 (Orchestrator 工具 —
`Ezagent.Orchestrator.Tools.update_agent_template` /
`add_agent_slot` / `remove_agent_slot`) 上线时是这个形状:

```elixir
defp do_spawn(template_uri, owner_uri, opts, ctx) do
  with {:ok, x1} <- step1(...) |> guard(:step1, ctx),
       {:ok, x2} <- step2(x1, ...) |> guard(:step2, ctx),
       {:ok, x3} <- step3(x2, ...) |> guard(:step3, ctx),
       ... (共 8 步) ...
       {:ok, xN} <- stepN(...) |> guard(:stepN, ctx) do
    {:ok, session_uri}
  end
end

defp guard({:error, reason}, step, ctx) do
  cleanup_partial(ctx)  # 枚举我们触及的 N 个 store,逐一拆除
  {:error, {step, reason}}
end
defp guard(ok, _step, _ctx), do: ok
```

`cleanup_partial/1` 必须**知道 Generator 至今触及的每一个副作用 store**
并逆向拆除:

- 活动的 `KindRegistry` pid — `Ezagent.SpawnRegistry.terminate`
- `WorkspaceRegistry` 绑定 — `WorkspaceRegistry.unbind`
- `AgentLineage` 行 — `AgentLineage.forget`
- 已提交的 `routing_rules` 行 — `RuleStore.delete_by_id` (通过线程化
  的 `routing_rule_ids` 累加器)
- (对于 `update_agent_template`) Session-Kind 的 `template_working_copy`
  slot tuple
- (对于 `add_agent_slot`) 已 spawn 的 worker Agent + 其 sidecar

意图:**让多步 Generator 操作看起来像原子操作** — 任何失败回滚之前
所有副作用,将系统还原到调用前状态。

---

## §2 轨迹 — 10 轮加固,HIGH 数始终卡在 1-2

Phase-7-completion 6-PR 工作 (#231..#237) 落地后,对 saga 模型进行
了反复的 codex adversarial-review。每一轮在某些地方降低了严重程度,
但 **HIGH 总数从未到 0**:

| 轮次 | PR | 严重程度 | 修了什么 |
|---|---|---|---|
| 1 | #239 | 1 CRITICAL + 3 HIGH | Generator / orchestrator 工具初次加固 — 首次审计发现 CapBAC + saga 都在漏 |
| 2 | #241 | ~2 HIGH | 第 2 轮修复 — cap 委托 TOCTOU + 持久化竞争 |
| 3 | #243 | ~2 HIGH | 第 3 轮 — orchestrator adoption + AgentLineage 分类边界 |
| 4 | #244 | 1 HIGH | 第 4 轮 — routing 操作改成事务式 (按步 `Repo.transaction`) |
| 5 | #245 | 1 HIGH | 第 5 轮 — `update_agent_template` 恢复链路 fail-safe 封装 |
| 6 | #246 | 2 HIGH | 第 6 轮 — `update_agent_template` 失败路径的最后剩余缺口 |
| 7 | #247 | 2 HIGH | 第 7 轮 — 只对 freshly-created worker 记录 lineage/binding (引入 `fresh?` 门) |
| 8 | #248 | 2 HIGH | 第 8 轮 — 非 fresh worker 不再启动 sidecar、Generator 不再 adopt |
| 9 | #249 | 1 HIGH | 第 9 轮 — Loader `fresh?` 门控 + Generator 多 slot cleanup |
| 10 | #250 | 2 HIGH | 第 10 轮 — 关闭两个 Generator 失败退出的 orphan 泄漏;spawner 清理自己的部分 spawn |

**规律**:每轮修了 *N* 个 store 的 cleanup 路径,codex 下一轮就找回
*N* 个相邻的 missed-store / TOCTOU / partial-recovery 边界:

- 第 7 轮引入 `fresh?` 门是因为 `Agent.spawn/4` 把
  `{:already_started, _}` 映射成 `{:ok, pid}`,然后**无条件 bind
  workspace + record lineage** — 当已有 pid 属于外部 lineage 时,
  这一步重新 parent 了它。修复:只对 freshly-spawned 才 bind/record。
- 第 8 轮发现 orchestrator 一侧对称的 bug — 非 fresh worker 仍在
  启动 sidecar。修复:sidecar 启动也要 `fresh?` 门控。
- 第 9 轮发现 Loader 是同一种形状 — workspace 模板 load_one 在 bind
  非 fresh 成员。修复:Loader `fresh?` 门控。
- 第 10 轮发现 Generator 多 slot 路径还有两个 orphan 泄漏出口。

这些发现是**相邻的、不是重复的**。每一轮都是真 bug。但收敛速率是
平的 — 总是还有一个 store、一个 TOCTOU 窗口、一条失败路径。

---

## §3 诊断 — 为什么枚举式 cleanup 在组合上是脆弱的

一个触及 `N` 个独立 store 的多步 Generator 操作 (`KindRegistry`、
`WorkspaceRegistry`、`AgentLineage`、`routing_rules`、working-copy
slot tuple、worker PtyServer sidecar、Identity caps 表 ……),**不能
通过在 `cleanup_partial` 中枚举这些 store 的方式实现事务性**。原因
复合放大:

1. **N 在增长**。每个新 Kind 类型 / 注册表 / 持久化旁路都给 cleanup
   增加一个必须知道如何回滚的 store。枚举是无上界的 — 每次审计都能
   找到"还有一个 store"。

2. **N×K 条失败路径**。有 `N` 个 store 和 `K` 步,就有 `N×K` 条
   (第 X 步失败时 store 1..X-1 已被触及) 的失败路径。每条都需要正确
   的 cleanup 前缀。codex 找的就是这些没被覆盖的前缀。

3. **gate-check 和 side-effect 之间的 TOCTOU**。当 gate ("这个 URI
   是否已被占有?") 和 side-effect ("spawn / bind / record") 不在
   同一个原子事务里时,外部进程可以在间隙里占有 URI。saga 无法补偿
   不是它造成的状态。

4. **不对称的原语**。`Agent.spawn/4` 不论是新 spawn 还是 adopt 现存
   pid 都返回 `{:ok, pid}`,对调用者是方便的,但**对 saga 的
   cleanup 是灾难性的** — saga 提交了"我 spawn 了 X"的墓碑,然后
   `cleanup_partial` 把不是自己创建的进程 terminate 掉了。

5. **cleanup 本身会失败**。在 `cleanup_partial` 里拆除一行已部分提交
   的 `routing_rules` 又是一次会竞争或失败的 DB 调用 — saga 没地方
   补偿这次补偿。

6. **一次失败 run 的残留会卡住下一次**。如果第 N 次调用的
   `cleanup_partial` 漏掉某个 store,第 N+1 次看到残留要么 adopt
   (错:重新 parent 外部工作),要么失败 (错:合法重跑无法继续)。

根本问题:**saga 的正确性是一个 N-store 穷举证明**。每次审计找到
下一个 N+1。失败路径数随着副作用步数组合增长,且系统每加一个
Kind 就再多一条。

---

## §4 正确的抽象 — converge-to-spec

Allen 2026-05-22:

> *"Generator 现在'原子多步 + 失败回滚'的模型是错的抽象 — 正确的是
> 声明式 SessionTemplate + reconciler(`spawn_from_template/2` 变成
> `docker-compose up`-style 收敛到 spec 的命令;残留状态是预期的;
> 再跑一次从失败点继续)."*

**重新框架**:

- `SessionTemplate` 是一份**声明式的期望状态规约** — session 应该
  有的 agent slots、routing rules、orchestrator、caps、working copy。
- Generator 的工作是 **`converge(spec, current_state)`** —
  docker-compose `up` 语义:
  - 已收敛的组件**被检测并跳过**;
  - 缺失的组件**向前补齐**;
  - 配错的 routing rule **向前修正**;
  - 上次失败 run 留下的残留是**预期的中间状态**,不是污染;
  - 用同样的 `(SessionTemplate URI, owner URI)` **再跑一次**就从
    部分状态继续到同一终态。
- 每个 per-Kind 操作在**原语级别已经独立原子**:
  `SpawnRegistry.spawn` 是一次 `DynamicSupervisor.start_child`;
  `RuleStore.add` 是一次 SQL insert 包在一次 `Repo.transaction` 里;
  `WorkspaceRegistry.bind` 是一次 ETS upsert。reconciler 在每步的
  幂等探针 (*spawn-if-missing*、*bind-if-unbound*、
  *insert-if-not-present-with-same-shape*) 背后组合这些原语。
- Generator 因此是一个 **SCRIPT,不是 transaction**。saga 回滚是
  错误的原语 — 正确的原语是**幂等的向前进展**。

代码库里**早已有先例**:
`Ezagent.Workspace.Loader.load_one/1` + `invoke_template/2` 处理
workspace 模板已经就是这个形状 — load 所有成员、re-spawn 缺失的、
`{:already_started, _}` → no-op、`fresh?` 门控 bind、错误 log 不
raise、重跑继续。Loader 是 Generator 的"哥哥"。**Generator 从一开始
就该是同一形状。**

---

## §5 修复 — PR-A 与 PR-C

### PR-A (#259, commit `350e9c3`) — Session.spawn_from_template/2 作为 reconciler

- `do_spawn/4` (8 步 `with` 链 + `guard/2` 包装) →
  `reconcile/2` — 一系列带幂等探针的逐步调用。
- `cleanup_partial/1` → **删除** (~400 LOC,涵盖 `session.ex` 里
  `spawn_from_template` 及其 `add_agent_slot` 调用路径)。
- 4 个新的 per-Kind 幂等辅助:
  - `Agent.spawn_fresh/4` — 报告 `:fresh | :already_started`,
    **不对 already_started 产生副作用** (让 reconciler 决定是否
    bind / record lineage)。
  - `WorkspaceRegistry.bind_if_fresh/2` — 只在 binding 缺失或匹配时
    bind。
  - `AgentLineage.record_if_fresh/3` — 只在 `:fresh` 时 record。
  - `RuleStore.upsert_by_logical_key/5` — 以规范化 matcher + scope
    tuple 为逻辑键的 insert-if-missing。
- Working-copy 合并:`populate_working_copy/5` 改为 MERGE (不是
  replace),merge 时重新校验每个 slot 的 ownership (覆盖本轮和
  上轮)。
- Orchestrator adoption gate 把 ABSENT-证据 和 POSITIVE-foreign-证据
  分开 (按 SPEC rev-4 对第 7 轮分类问题的修复) — absent 带界限延迟
  重试;positive 干净地返回 `:foreign`。

### PR-C (#260, commit `526c401`) — orchestrator 工具作为 reconciler

- `update_agent_template`、`add_agent_slot`、`remove_agent_slot` —
  改为调用新的 reconciler,而非各自的 per-tool saga。
- `apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex` 里
  约 6 个 saga 补偿辅助**删除** (rollback_template_slot、
  restore_prior_working_copy、cleanup_routing_changes、per-tool
  `guard` 封装……)。
- Cap 幂等探针用**逻辑等价** (忽略 `granted_at`) —
  `grant_cap_if_absent` 是 reconciler 的 cap 辅助。
- Routing rule 幂等要求 `enabled == true` AND 规范化 matcher 等价
  (rev-2 对 SPEC §2 step 4 的修复)。

合并 LOC 变化:**约删除 800 LOC**,跨 `session.ex` +
`orchestrator/tools.ex`;净新增是 4 个 per-Kind 幂等原语 (~80 LOC)。
重构后代码库**实测更小**。

---

## §6 这验证了什么 — 设计原则

reconciler 溶解是 `ezagent-developer` SKILL 中**两条设计原则的案例
研究** (使用 SKILL 权威编号 P1-P26):

### P2 "let-it-crash;不要 workaround、不要默认值、不要 whitelist"

saga 模型在结构上**就是 workaround** — 它试图在 Generator 内部用
默认值吸收 N-store 枚举问题 ("如果第 7 步失败,默认把 store 1..6
拆掉")。每一轮 codex 加更多默认值:`fresh?` 门控默认、"非 fresh
则跳过 sidecar"默认、"Loader 见到已存在成员则跳过 bind"默认。每
个默认单独看都正确。**累积就是反模式**。

reconciler 是**结构性修复** — 它删除整个 saga 表面 (`guard` /
`cleanup_partial` 机械) 并替换为幂等的 per-step 原语。**没有可以
默认的对象** — 重跑要么收敛,要么返回带类型的 partial 状态。

### P3 "任何数据只有单一事实源"

saga 让 `cleanup_partial` 枚举 store **作为一个独立记录**记下
"Generator 刚做了什么" (线程化累加器)。那个累加器是 store 实际
状态之外的**第二事实源** — 两者之间的分歧就是 codex 一直在找的
bug 类。

reconciler **溶解了累加器**:SessionTemplate 是"应该存在什么"的
事实源;活动状态是"实际存在什么"的事实源;reconciler 是函数
`converge(spec, current)`。**没有"我刚做了什么"的独立记录可以
drift**。

### 插件/Kind 契约 — `Workspace.Loader` 是先例

`Ezagent.Workspace.Loader` 自从 workspace 模板引入起就是这个模式。
**它就是代码库里 reconciler 的先例** — 已经 `:already_started`-安全、
已经 `fresh?` 门控、已经重跑幂等。Generator 从一开始就该按 Loader
建模。SKILL 的 **§"How-to: add a Template Class"** 现在把 Loader
列为 canonical reconciler 模式;**新的 spawn 多 Kind 状态的 Template
Class 应该跟这个形状**。

---

## §7 加固轮次中**保留**的东西

10 轮 codex 工作**不是浪费**。reconciler 保留了若干加固期间引入的
load-bearing 内容:

- **第 1-3 轮的 CapBAC + workspace-isolation 修复** — 这些是*真
  安全*修复 (跨 workspace cap 泄漏、identity-grant authority
  preflight、cap 委托的 TOCTOU)。它们与 saga/原子性问题**正交** —
  reconciler 依赖它们。
- **第 7 轮及之后的 `fresh?` 门控** — reconciler **基于**第 7 轮
  催生的 `Agent.spawn_fresh/4` 原语构建。bug ("非 fresh adoption
  错绑 workspace + lineage") 是真的;修复 ("只对 `:fresh` 才
  bind / record") 是正确的;reconciler 到处都在用。
- **第 8 轮的"非 fresh worker 不启动 sidecar"** — 同形状、同原语,
  原样保留。
- **第 10 轮的"spawner 清理自己的部分 spawn"** — Generator 的 per-step
  仍然清理**它自己 spawn 的即时失败** (一次返回 `{:error, _}` 但
  尚未副作用的 `Agent.spawn_fresh`)。这是局部、有界、**不是**多步
  saga。reconciler 保留这个。
- **第 4 轮 routing 操作的 `Repo.transaction`** — reconciler **内部**
  的 per-step 原子原语。routing 操作仍然包在单个 SQL 事务里;
  reconciler 依赖这个原语实现 routing 幂等。

换句话说:这些轮次把**每个原语的正确性**做对了。reconciler 保留
这些原语。它删除的是构建在它们之上的**多原语枚举**。

---

## §8 要记住的反模式

**三个字概括反模式**:*"再加一步 cleanup 就好"*。

当一个多步操作失败、你想在 `cleanup_partial` 枚举里再加一条时,
**停下来问**:

> *"为什么需要 cleanup?这个操作的 converge-to-spec 模型是什么?"*

如果这个操作有声明式规约 (SessionTemplate、Workspace 模板、
deployment manifest,任何说"系统应该有 X"的东西) 且有幂等原语
(`spawn-if-missing`、`bind-if-unbound`、
`insert-if-not-present-with-same-key`),那么这个操作是 reconciler,
不是 saga。**写成 reconciler。删掉 cleanup 枚举**。

如果这个操作**没有**可收敛的规约 (一次性的"从账户 A 扣款,贷记到
账户 B",没有声明式终态),那么 saga *可能*是正确的原语 — 但请
**用 saga 库** (例如 `Sage`、`Commanded`),它们已经把 N-store 枚举
形式化解决了,不要手写 `cleanup_partial`。

---

## §9 编号 LESSONS — 给将来开发者

### LESSON 1 — *跨 N 个 store 的 saga 是一份随 N 增长的证明义务。*

如果你在写 `cleanup_partial` 并枚举触及的 store,你就**签约维护
这份名单随系统增长**。每新加一个 Kind / 注册表 / 持久化旁路就
多一条。审计成本是永久的。**写 saga 前,先看操作是否有声明式规约
— 有就改写成 reconciler**。

### LESSON 2 — *Kind 层级的幂等原语溶解 Generator 层级的多步 saga。*

`Agent.spawn_fresh/4` (报告 `:fresh | :already_started` 而不产生
副作用)、`WorkspaceRegistry.bind_if_fresh/2`、
`AgentLineage.record_if_fresh/3`、
`RuleStore.upsert_by_logical_key/5` — 这些 per-Kind 幂等辅助是
reconciler 形状成为可能的关键。当你新增一个会被多步 Generator
触及的 Kind 时,**幂等原语要和 Kind 同步交付**,不是等 Generator
需要时才补。

### LESSON 3 — *隐藏 `:already_started` 的便利原语是 saga 的敌人。*

`Agent.spawn/4` 不论 fresh 还是已存在都返回 `{:ok, pid}`,对调用者
*方便*,但**正是第 7..10 轮"非 fresh adoption" bug 的根因**。
reconciler 需要知道 `fresh | already_started` 才能做出正确的下游
决策 (bind 吗?record lineage 吗?启 sidecar 吗?)。当你写"spawn"
原语时,**优先选择暴露这个区分的版本**;不在乎的调用者可以
`_ -> :ok` 匹配。

### LESSON 4 — *设计新 saga 之前,先在代码库里找 reconciler 先例。*

`Ezagent.Workspace.Loader` 在 Generator 被设计成 saga 的时候已经是
reconciler。没人注意到这种不对称,直到 10 轮 codex 之后。**当你设计
一个新的多 Kind orchestration 时,grep 代码库里其他多 Kind 状态
orchestration。如果它们是 reconciler 而你要写 saga,这种不对称
大概率是你设计的 bug**。

### LESSON 5 — *adversarial-review 的收敛速率是抽象的信号,不是工程的信号。*

如果 10 轮代码审计每轮都找 1-2 个 HIGH 且严重程度不下降,**抽象
错了**。停下审计循环,问架构问题。codex 在每一轮都是正确的;工程
是好的;*设计*才是 bug。(同样信号适用于人工审计 — 多轮 HIGH 数
持平意味着你没在收敛。)

---

## §10 这份文档的定位

| 文档 | 用途 |
|---|---|
| `docs/superpowers/specs/2026-05-23-generator-reconciler.md` | 重构的 SPEC (rev 4 — 3 轮 codex 审计) |
| `docs/superpowers/specs/2026-05-22-phase-7-completion.md` | Phase-7-completion SPEC (rev 5) — atomic-saga 部分现已标注 SUPERSEDED |
| `docs/notes/phase-7-implementation-audit-2026-05-22.md` | 触发 6-PR + 10 轮工作的审计 (现已加入 2026-05-23 RESOLUTION 头部) |
| `docs/notes/phase-7-handoff.md` | Phase-7 发布定调 (现在反映 reconciler-validated 状态) |
| **本文档** | 复盘 — *为什么* saga 不行、*reconciler 是什么*、*将来开发者要记住什么* |

重构的 PR 序列:PR-A (#259) + PR-C (#260) + PR-D (本文档 + supersede
注释 + SKILL 指针)。

— 2026-05-23,Claude (Opus 4.7) 撰写,按 Allen 飞书 2026-05-23。
