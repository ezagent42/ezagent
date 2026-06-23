# 架构决策:保留自研的 `ezagent_core` 框架

**日期:** 2026-06-20 · **状态:** 决策已记录 · **决策人:** 林懿伦(Allen)

> 取证/决策笔记。规范性架构见 `../../ARCHITECTURE.md` + `../../GLOSSARY.md`(决策日志)。
> 本文记录*为什么*保留自研的 Kind/Behavior actor 框架,而非迁移到 Ash 或其他框架。
> (英文正本:`2026-06-20-bespoke-core-framework-roi-decision.md`)

## 问题

`apps/ezagent_core` 含一套**自研框架**——Kind/Behavior actor 运行时,约
**37.6K 行,占代码库 ~30%**。调研两点:
1. 以系统功能复杂度衡量,代码总量是否*健康*?
2. 把自研框架迁移到 **Ash**(或其他成熟框架)ROI 是否划算?具体:有没有成熟的
   **actor** 框架可以迁移?

## 结论(TL;DR)

**维持自研 `ezagent_core`,继续建在裸 OTP 上。** 这是*正确分层*,不是冗余:成熟
OTP 原语(本来就在用)+ 一层没有任何现成库能提供的、必要的领域抽象。

- **Ash** 是声明式*资源/数据/授权*框架,**不是** actor 框架,替代不了运行时。
  仅 greenfield 适用:新的数据密集/关系型功能 + 其授权可以用。
- **没有成熟框架能替代 actor 抽象。** 原语(`GenServer`/`DynamicSupervisor`/
  `Registry`,+`Horde` 做分布式)成熟且已在用;抽象(Kind/Behavior/slice/effects
  文法/内联 CapBAC/URI 寻址)**本就该自研**。
- **Commanded(CQRS/事件溯源)** 是唯一范式级替代,但它是*重写而非迁移*,且其主要
  收益基本已在内部实现。对现有代码库 ROI 为负。

## 证据 —— 四份调研(2026-06-20)

### 1. 代码构成
生产 `lib/` ≈ **125K 行**(`wc -l`;占比可信,绝对值偏高 ~25-40%)。测试 ≈ 123K(≈1:1)。

| 类别 | 占生产 lib |
|---|---|
| 业务逻辑 | ~46% |
| 基础设施/框架(自研 Kind 运行时、Ecto、registry、URI) | ~29% |
| UX(LiveView 15K + web + CLI/mix-task 9K + JS) | ~18% |
| **权限(CapBAC)** | **~7%** |

**核心洞察:** 权限是一层**薄(~7%)但无处不在**的横切层——~83 个 per-action `caps:`
门散布在业务 Behavior 里(#154 设计:每动作受 cap 约束、每 cap 溯源到真实实体)。

### 2. 体量对比(自测,同一 `wc -l` 指标)
Ezagent-ng ~125K;Plausible 79K / Livebook 68K / elixir-ls 66K / Ash(框架)140K /
Oban(库)14K / CrewAI 110K、LangGraph 82K(Python)。

**结论:健康,甚至偏精简。** 减掉 ~37K 自研框架 → **~88K 应用代码**,正落在 Elixir
应用带(66-79K),而功能域更广。多数应用从 `deps/` 免费获得运行时;我们 in-tree 自带,
所以公平对比是 **88K 而非 125K**。测试比 1:1 健康。

### 3. Ash 迁移 ROI —— 不值得
- Ash 自述"声明式数据管理框架";"资源"= 一行可加载/修改/保存的数据库记录,不是活进程。
- 37.6K 拆分:**~9-20K Ash 敌对的 actor 运行时** + **~5.5K 无关 dev 工具(mix/gate)**
  + **~1.7K 授权(可重写非可删)** + 仅 **~3-5K Ash 可处理的关系型存储**。
- **持久化这个"看似该用 Ash"的点恰是陷阱:** 快照是 `:erlang.term_to_binary` 把 slice
  整块序列化成不可查询的 `state_binary` blob(`ecto/kind_snapshot.ex`)——对 Ash 天然敌对。
- 迁移 = 多季度地基重写 + 重新移植 88K 应用层(116 文件引用 `caps:`;91 个 required_caps;
  30 Behavior;5 Kind)到*不同编程模型*,净收益却只有个位数 K 行。**ROI 负。** greenfield ≠ 迁移。

### 4. actor 框架迁移 —— 抽象层没有成熟目标
- **原语 vs 抽象:** `kind/server.ex` 本身就是 GenServer + DynamicSupervisor + Registry
  ——我们已坐在成熟原语上。"迁移到成熟原语"= 空操作(或 +Horde 做分布式;Horde pre-1.0)。
- **Commanded ROI:** 真正代价是**真相之源反转**(当前=状态快照;Commanded=事件日志为真相,
  靠重放重建)。而其卖点(事件+saga)**基本已内部实现**——`event_log.ex` + `saga_runner.ex`
  已存在,effects 文法已发事件+跑 saga。真正新的只有重放重建+读模型投影,现在不需要。
  PTY/流式仍需活 GenServer;CapBAC 授权仍自研。**迁移 ROI 负。**
- 其他(Phoenix/AshSM/Broadway/GenStage/Membrane/Oban/Ra)均不匹配;Akka/Orleans/Dapr/Ractor 离开 BEAM,出局。

## 运营建议
- **现状(brownfield):** 维持自研抽象建在裸 OTP——正确分层。
- **分布式:** 需要多节点时再上 **Horde**(低风险替换 DynamicSupervisor/Registry;注意 pre-1.0)。
- **新关系型/数据密集表面:** **Ash** 作数据+授权+API 层是合理的 greenfield 选择——补充,非替代。
- **Commanded/事件溯源:** 仅当事件溯源本身成为*产品*需求(那是新系统,不是迁移)。

## 为什么重要
那 30% 自研框架让 Ezagent-ng 对比 stock-Phoenix 应用"看起来大",但它是**"活的多智能体 actor
系统 + 细粒度 CapBAC"的本质成本**,不是意外臃肿。框架市场解决的是*原语*(已在用)和*正交范式*
(数据层/事件溯源),而非我们构建的"可组合 Behavior + 内联授权"的实体运行时。保留它在经济上和
架构上都是正确决策。
