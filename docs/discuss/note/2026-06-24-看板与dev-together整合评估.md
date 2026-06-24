# 讨论记录：看板(kanban) × dev-together 怎么整合

> 2026-06-24 · 背景：同事提出"看板工具应该和 dev-together 合并，用于分发任务和返回 handoff"。
> 评估方式：派 agent 通读 dev-together skill + 看板定版文档(07) + 看板实现 + path B agent handoff。

## 一、结论先行

**不是"合并成一套"，是两层对接**：看板做调度器、dev-together 做执行器、关键节点回写看板。
揉成一套是错的——会让"一天的循环"和"跨周的产品链"在同一份文档里打架。

## 二、两者是两层，不是两个视图

| | 看板（mindmap 流程工具） | dev-together |
|---|---|---|
| 粒度 | 产品全链：定位→PR（9 棒） | 开发执行：一天的 task→分支→merge |
| 时间 | 跨周/跨迭代（这周开发、下周验证） | 一天一循环（`docs/together/<日期>/`） |
| 真相源 | 节点树快照（owner/status/artifacts/metrics，产品真相） | 当日操作记录（plan/handoffs/returns/stack/review，markdown） |
| 谁用 | 产品负责人/运营/产品/设计/研发 5 角色 | lead + dev（hat，可人可 agent） |
| 独有 | 指标回收 + 不达标 drop 砍子树 | DoD=可演示产物 + per-task-branch + lead 唯一进 main |

**关键**：dev-together 恰好是看板 **第 7-8-9 棒（issue→测试→PR）那段的日常协作机制**。07 文档第 8 棒工具列已写明走 dev-loop——作者本来就把 dev-together 当执行后端，不是平级替代。

## 三、怎么接：4 个回写动作（dispatch 层已全有，MVP 零代码）

| dev-together 命令 | 回写看板（现成动作） |
|---|---|
| `handoff` | 从 issue 节点的 spec卡/Gherkin **生成** handoff（不另写需求） |
| `dive`（接手） | `claim_node`（owner=dev → status=claimed/doing） |
| `return`（交活） | `register_pr`（PR 挂到 pr 节点） |
| `close`（合 main） | `set_status done`（看板 `sync_prs` 已能自动轮询 merged→done） |

**两个真相源各管各的**：看板答"这个 feature 跨周进展到哪"，dev-together 答"今天这个 task 怎么干"。
看板节点只挂**指针**（指向 `docs/together/<日期>/handoffs/x.md` + DoD 截图），**不复制全文**，互不污染。

回写动作 `claim_node`/`set_status`/`register_pr`/`sync_prs`/`attach_artifact` 在
`apps/ezagent_plugin_world/lib/ezagent/world/mindmap_actions.ex` **已全部落地 + e2e**。

## 四、跟 path B agent 一致吗：同一条线，上下游

- path B 要的"agent 听人话改图（认领/改状态/挂PR）"= **正是这 4 个回写动作的执行者**。一个 agent 既当 dev-together 的 lead/dev，又操作看板（skill 明写 role 是 hat、可人可 agent）。
- 分工：**path B = 机制**（agent 怎么调到改图动作，3 个缺口卡 Allen）；**对接 = 编排**（什么时候回写，skill 文档层约定，不卡 Allen）。
- **可并行**：MVP 先人手在 world UI 点（dispatch 就绪），不用等 path B；path B 落地后把"人手点"升级成"agent 自动调"。

## 五、落地路径

**MVP（现在就能做，不卡 Allen）**：
1. dev-together skill 加一节"看板对接 + 上面的映射表"。
2. 约定 issue 节点是 handoff 的唯一 spec 来源（对齐 07 第 7 棒钦定）。
3. `dive/return/close` 各加一步"回写看板"（人手点，dispatch 全有）。
4. DoD 截图 / handoff.md 作为 artifact 指针挂回节点。

## 六、卡 Allen 的 3 处（待拍板）

1. **"done"的语义**：close 后看板自动 done，但产品层指标还没回收——看板缺一个"已合但指标待验证"的态（现仅 unassigned/claimed/doing/done）。这是 done 与 drop 闭环的接缝。
2. **自动回写 vs 手动**：让 dev-together 命令自动 dispatch 回写 = 掉进 path B 的 3 个工具集缺口（MCP 工具 / cap grant / skill 解析）。
3. **drop 触发**：要不要在 dev-together `review`（日终）加"看板该 drop 哪些子树"的钩子。

## 七、一句话收口

看板管"产品链跨周进展 + 指标 drop"，dev-together 管"当日 task 怎么干 + 唯一进 main 的路"，
接缝是 4 个回写动作，全部已有 dispatch。path B agent 是把回写从"人手点"升级成"agent 自动调"
的技术线，和对接方案是上下游不是对立。MVP 先用人手点跑通，不必等 path B。
