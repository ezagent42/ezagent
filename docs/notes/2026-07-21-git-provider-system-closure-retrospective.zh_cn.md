# Git Provider 系统闭环复盘

> 日期：2026-07-21
> 来源：Git Provider V1 Plan D1 / PR #1445 工作会话
> 证据规则：已证事实、有依据的推断和未知项分别标注。

## 1. 结果与时间线

**已证事实。** D1 按多个 Task 实施和评审，但正确性依赖同一条系统级
生命周期：provider 所有权、持久 journal、credential effect、恢复、独立补偿、
handoff shredding 和终态释放。局部检查可以转绿，后续跨 Task 评审仍能发现
生命周期违规。架构和文档门禁运行较晚，当时大量实现已经冻结。

同一工作会话还观察到运行 Mix/BEAM 检查时 WSL 资源失控。之后受控运行的
局部和 provider domain 检查约使用 230–350 MiB；此前观察到 VmmemWSL 增长
6–7 GiB。

**有依据的推断。** 受控运行的工作集说明普通局部测试不太可能解释 6–7 GiB
增长。两个事件都指向同一方法缺口：工作在缺少整个生命周期的 Plan 级负责人
和证明时被视为局部完成。

**未知。** 原始失控进程树及其创建者没有被保留，因此本文不把原因归给任何
进程、命令或 agent。本文也不重建精确时间戳，不声称所有 D1 修复只有一个根因。

## 2. 流程循环与 WSL OOM

### X 问题——根本问题

Mix/BEAM 调用被建模成一个已经启动的命令，而不是拥有单一进程树、串行化、
资源边界、期限、清理和完成证据的有主有界作业。

### Y 问题——工程问题

- 裸跑或重叠的 Mix/BEAM 调用没有进程级全局锁。
- 没有 cgroup 内存/交换边界、scheduler 限制或标准超时。
- 未强制测试 partition 唯一。
- 没有一致记录退出码、耗时、Max RSS、swap 和孤儿进程证据。
- VM 级 OOM 在等待中的 agent 看来可能只是断连。
- OOM 前的进程树和 BEAM/ETS 证据不足，无法识别原始失控创建者。

### X 级修正

把每次本地 Mix/BEAM 验证定义为有主作业。它的完成包括独占准入、有界进程树、
明确期限和资源上限、原样返回子进程退出状态，以及运行后的孤儿进程证据。

### Y 级修正

采用受控 Mix runbook 和已批准方法产品化设计中的单一 runner。使用
`/tmp/ezagent-mix.lock`、user-systemd scope、`MemoryHigh=4G`、
`MemoryMax=5G`、`MemorySwapMax=0`、`ERL_FLAGS='+S 4:4'`、唯一 partition
和明确超时。保留资源和失败证据，不用重跑结果覆盖它。

### 防复发证明

runner 契约测试必须检查串行化、精确资源边界、argv 保真、退出码传递、
超时/资源分类、前置依赖缺失、stderr 和锁超时。dev-together handoff 必须写明
runner、上限、超时、partition 和串行规则。CI 必须拒绝删除或漂移这些契约。

## 3. Task 局部收敛与重复跨 Task 修复

### X 问题——根本问题

多个 Task 被当作独立正确性闭环，但 D1 正确性实际存在于同一跨 Task 状态机。
规划和验收单元小于需要证明的不变式。

### Y 问题——工程问题

- 修复按文件或 Task 局部收敛，并反复暴露下一条跨 Task 边。
- DB、runtime 和 fixture 表示漂成了不同状态机。
- 局部绿灯在没有集成 Closure checkpoint 时被当成闭环。
- 不可变历史证明与可变的当前阶段谓词混用。
- 需要持久证明时却接受了终态工作流标签。
- 证明和发布被解锁窗口分隔，形成 TOCTOU。
- 并行评审在局部实现冻结后才发现竞态。
- 迟到的架构/文档门禁在末期才暴露结构性所有权漂移。

### X 级修正

围绕显式系统 Closure 规划工作。每个 Closure 拥有一个 X 问题、一个 Plan
不变式、相关 Task、持久证明、集成证据和资源边界。Task 实现矩阵单元，不能
单独宣称 Plan 已闭环。

### Y 级修正

在 dev-together board 加入结构化 closure matrix，card 和 handoff 引用 closure
id。同一共享状态机的实施和修复必须串行。第二次出现跨 Task 回归后，停止局部
补丁并写出 `failure -> Plan invariant -> one root cause -> one integrated repair surface`。
并行只读评审前冻结实现，再把发现合并为一批修复。

### 防复发证明

board schema、renderer、handoff/review 模板和 CI 契约必须同时要求 Plan 级
Closure 和结构化 method delta。Plan 被称为完成前，review 必须逐个 Closure
核对持久证明和集成证据。

## 4. 其他系统发现

| 发现 | 证据状态 | 方法含义 |
|---|---|---|
| 终态标签与持久证明 | **已证：** 工作流标签本身不能证明持久 effect、恢复、补偿、shredding 或释放。 | 写明持久记录以及证明它的查询/断言。 |
| DB/runtime/fixture 漂移 | **已证：** D1 修复期间三种表示编码了不同生命周期假设。 | 维护一个显式状态模型，并用它测试全部表示。 |
| 证明/发布 TOCTOU | **已证：** 证明、解锁、发布分阶段形成了变更窗口。 | 让证明与发布同一保护，或在发布保护内重新验证。 |
| 历史证明与阶段谓词 | **已证：** 不可变证据曾与当前阶段条件混用。 | 历史事实不可变保存；当前谓词从当前状态计算。 |
| 迟到的架构/文档门禁 | **已证：** 迟到门禁在局部工作冻结后发现结构性所有权漂移。 | 第一个 Closure checkpoint 和最终集成都运行结构门禁。 |
| Identity 全量套件失败 | **已证：** 曾观察到失败；**未知：** 受控重跑未复现，故不归因为产品或 fixture。 | 在新证据重新分类前，保留为未复现的并发污染。 |
| 远端漂移 | **已证：** 设计期间无法 fetch 远端 main `0a44d7b5`，设计分支从本地 `origin/main` 快照 `5afe9aa31` 开始。 | 记录 base 和远端状态；传输恢复后在实施/交回前 rebase。 |
| agent/网络限制 | **已证：** agent 断连和 Git 传输不可用限制了观察。**未知：** 两者都不能证明底层产品原因。 | 基础设施证据与产品证据分开，不用推测填空。 |

## 5. D1 期间发生的改变

**已证事实。** D1 修复处理了具体的所有权、journal、credential、恢复、补偿、
shredding、释放、fixture 和门禁发现。局部及 provider domain 检查在受控资源
边界内重跑。工作会话还产出了 X/Y 分析和已批准的四层产品化设计：取证记录、
操作契约、可执行保护和工作流契约。

这份复盘记录方法证据；它不改变 Git Provider runtime 语义，也不修订冻结的
D1 spec 或 implementation plan。

## 6. 仍然存在的流程债务

- 交付并强制执行 guarded runner 及其 CI 契约。
- 在 dev-together artifact 加入 Plan 级 Closure、资源边界、Stop Rule、评审
  拓扑和 method-delta 要求。
- 另行决定是否让所有本地和 CI Mix 命令经过 runner；已批准的第一步只覆盖
  安全本地路径及适用 handoff。
- Identity 全量失败仅在携带进程、partition、数据库和测试证据再次发生时调查。
- 保留远端/base 漂移证据，并在 handoff 边界验证 rebase。
- 没有新保留证据时，不得声称已知原始失控创建者。

## 7. 需求到证据矩阵

| 需求 | D1 证据 | 持久落点 | 闭环证明 |
|---|---|---|---|
| 有主有界 Mix 作业 | 230–350 MiB 受控运行对比观察到的 6–7 GiB VmmemWSL 增长；原始创建者未知 | 双语 runbook + guarded runner | runner 契约套件和结果摘要 |
| 精确 X/Y 框架 | 重复局部修复没有表达 Plan 不变式 | 复盘 + dev-together 模板 | CI 契约拒绝缺字段/术语漂移 |
| Plan 级闭环 | 从所有权到终态释放跨越 Task 边界 | `board.yaml` closure matrix + handoff 引用 | review 核对持久和集成证据 |
| 持久证明 | 标签、历史事实和当前谓词曾被混用 | closure matrix 和 review method delta | 每个 Closure 有具名持久查询/断言 |
| TOCTOU 安全发布 | 证明和发布之间存在解锁窗口 | Plan 不变式及集成修复面 | 保护内发布或保护内重新验证 |
| 失败完整性 | Identity 失败未复现；重跑不能抹除 | runbook 分类和保留证据 | 首次失败记录加后续运行结果 |
| 尽早运行结构门禁 | 迟到门禁发现所有权漂移 | handoff/Plan checkpoint | Closure checkpoint 和集成时运行门禁 |
