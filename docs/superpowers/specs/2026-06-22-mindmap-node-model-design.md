# 设计 · mindmap 节点数据模型（增量3：全链路拓扑节点 + 认领/状态/挂载/指标 + CapBAC）

> 分支 `feat/df-tech`（基于 a6fa6db3）。承接增量1（节点树 Kind）+ 增量2（durable）+ 增量4出站（Miro）。
> 按 dev-together `handoff-standard` 结构写；DoD=可演示产物；杜绝想象（引用带 file 路径）。

## 0 · Mission
把 mindmap 节点从"只有 `{parent_id,title,order}`"扩成 **df-prd 要的全链路拓扑节点**：每个节点处在产品链某一阶段，能**认领、记状态、挂载工具产物、挂指标**，权限按 ezagent 方式（CapBAC）。

## 1 · Required reading
- `.claude/skills/ezagent-developer` + `references/new-contract.md`（Behavior 契约：`use Ezagent.Lifecycle` + `action` + `{:set}`/`ctx[:read]`）。
- `.claude/skills/dev-together/references/handoff-standard.md`（本 spec 遵循）。
- df-prd `04-spec与用户旅程.md` 功能1（节点认领 + 四态状态机，权威需求）。
- 既有：`apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex`（增量1 Behavior）。
- 不碰 world（本增量纯后端）；若后续做 world 编辑面再读 `docs/guide/world-coordination.md`。

## 2 · Locked decisions（纠正后，brainstorm 已定，勿再议）
- **mindmap = 整条产品链的核心拓扑树**（发心→价值→模块→功能→开发→运营指标→ROI 回环），**不是** dev-together。dev-together 只是"开发"阶段节点上挂的一种产物。
- **ezagent 是真相源**；节点 state 仍收在**单一 `:tree` key**（沿用增量1/2，arch.scan set_effect_sites 友好）。
- **两个维度分开**：
  - **"工具里做" vs "mindmap 里做"**：节点的**细状态（review / CI / merge 等）handoff 给外部工具（github 等）**去管，经挂载的 artifact（PR 等）反映回来；**mindmap 自己的 `status` 保持粗粒度**（只 4 态，不塞 `:review`）。
  - **权限（CapBAC）= admin + 每个节点自己的 owner（= 认领人）**：`data_owner/1` 返回**目标节点的 owner**；ezagent 原生 authz = **admin（持 admin cap）或该节点 owner** 才能改。一个 owner 概念**既是问责又是权限闸**（认领=拿到编辑权），比 stage-owner 简单。`stage` 退回纯**分类字段**（节点在链条哪阶段），**不是权限边界**。
- **不变式**：`owner==nil ⟺ status==:unassigned`（不存在"既没认领也没标待分配"的灰节点，df-prd 04-spec §50）。

## 3 · 节点 schema（扩展 `:tree.nodes`）+ 实例级权限映射
```elixir
# 每个节点
node = %{
  parent_id, title, order,                         # 拓扑（增量1）
  stage:     :purpose | :value | :module | :feature | :dev | :ops,  # 链条阶段
  owner:     String.t() | nil,                      # 认领人=Entity.User URI；nil=待分配。既是问责也是权限闸(data_owner)
  status:    :unassigned | :claimed | :doing | :done,  # 粗粒度4态(对齐df-prd); 细状态归工具
  artifacts: [%{tool: String, kind: String, ref: String, url: String}],  # 挂载工具产物
  metrics:   [%{name: String, target: number|String, current: number|String|nil, unit: String}]
}
```
（无实例级权限映射——权限就是每个节点的 `owner`，admin 走 admin cap。`stage` 仅分类。）
- **status 只 4 态、跨 stage 通用**（功能点 done=闭环；ops done=达标）。**细状态（review/CI/merge）不进 mindmap**——handoff 给 github 等工具，经 artifact 反映。
- **artifacts 挂任意工具产物**：dev 阶段挂 `%{tool:"github",kind:"pr",ref:"#123",url:…}` 或 dev-together handoff；产品阶段挂 doc/spec；导图初稿挂 xmind 引用。**谁来填/同步由别的插件经 dispatch attach_artifact 做（零耦合）**。
- **metrics 一等字段**：价值/ops 节点挂指标（周闭环数/对齐时长/ROI…）——承载 df-prd"设运营指标检测"。

## 4 · 新增动作（`Ezagent.Behavior.Mindmap`）
| action | args | 效果 | cap |
|---|---|---|---|
| `set_stage` | `%{id, stage}` | 改节点阶段 | owner/admin |
| `claim_node` | `%{id}` | owner=caller、status :unassigned→:claimed | 任意成员(认领自己) |
| `unclaim_node` | `%{id}` | owner=nil、status→:unassigned | owner/admin |
| `set_status` | `%{id, status}` | 状态流转（校验合法迁移 + 不变式）| owner/admin |
| `attach_artifact` | `%{id, artifact}` | artifacts 追加一条 | owner/admin |
| `detach_artifact` | `%{id, ref}` | 移除一条 | owner/admin |
| `set_metric` | `%{id, metric}` | metrics upsert（按 name）| owner/admin |
- 增量1 的 `add_node` 默认 `stage` 继承父、`owner=nil`、`status=:unassigned`、`artifacts=[]`、`metrics=[]`（向后兼容）。

### CapBAC（= admin + 节点 owner，遵从 ezagent、最简）
- **`data_owner/1` 对目标节点返回 `node.owner`**（接 identity 域 grant 收口）。于是 ezagent 原生 authz = **admin（持 admin cap）或该节点 owner** 才能改这个节点（rename/move/remove/set_status/attach/detach/set_metric/set_stage）。
- **`claim_node`**：对**未认领**(owner=nil)节点，**任意成员**可领（owner=caller、status→:claimed）。已认领的只有 owner/admin 能 `unclaim`。
- **`add_node` 加子**：admin 或**父节点 owner**（你拥有的分支才能往下加）；建顶层节点 = admin。
- 一句话：**认领=拿到这个节点的编辑权；admin 管全树**。未认领节点只有 admin 能改（直到有人领）。无自造权限字段、无实例级映射——纯 ezagent `data_owner`+cap。

## 5 · markmap / Miro 兼容
- markmap render/parse 只表达拓扑（title/层级）；owner/status/artifacts/metrics **不进 markdown**（markmap 是视图、装不下）——它们只在 ezagent 真相源里。导出时可选在 title 后缀 `[@owner ·status]` 做只读提示（不解析回）。
- Miro 出站：节点 push 时可把 status 映射成节点颜色、owner 映射成 tag（增量4下半，本增量不做）。

## 5.5 · 全链路流转 + 可追溯（以你的开发例子为准）
mindmap 是**编排骨架**：数据沿拓扑**往下流（需求）**、结果**往后流（状态/价值）**。一个 dev 例子：

```
功能点节点(stage :feature, 含验收要求)
   └─ 开发任务节点(stage :dev, assignee=某dev, 挂 github PR artifact)
        │  ① github CI 读"功能点的验收要求"(经 dispatch get_tree/get_node)→ 校验 PR 充分必要
        │     (开发=功能点要求, 不做冗余开发) ② CI过+PR合 → github 插件 dispatch
        │     set_status(:done)+attach_artifact(merged PR) 回写到这个 dev 节点
        ▼
   运营节点(stage :ops, 挂价值闭环指标)
        ③ dev 节点 :done 触发 → 进运营阶段验证价值闭环(metrics)
```
数据格式如何承载（**不新增复杂度，全用现成机制**）：
- **需求往下**：功能点节点的验收要求存它自己（title/一条 `spec` artifact）；dev 节点是它的**子节点**(拓扑即追溯链：dev 实现哪个功能点一目了然，支撑"充分必要/无冗余"的覆盖视图)。CI 经 **dispatch 读** 拿到。
- **结果往上**：CI/PR 结果由 **github 插件经 dispatch `set_status`/`attach_artifact` 回写**（零耦合，§二点已述）。
- **跨阶段触发**：`set_status` 把节点置 `:done` 时，handler 额外发一条 **`{:emit, node_status_changed}` effect**——下游（运营节点 / 监听的 agent / 自动化）据此推进（如激活运营节点去验证价值闭环）。
- ⚠️ 本增量只把**数据 + 动作 + emit 钩子**做好；**真正的 CI 集成、ops 自动触发、覆盖性"充分必要"校验**=各工具插件经 dispatch/订阅 emit 实现，排在后续增量（架构已支持）。

## 6 · Definition of Done（可演示产物 + 全 gate）
- **e2e 输出**：dispatch `add_node`→`claim_node`(以某 User 身份)→`set_status :doing`→`attach_artifact`(github PR)→`set_metric`→`get_tree` 显示 owner/status/artifacts/metrics 都对；**另一个非 owner 非 admin 身份** dispatch `set_status` → **被 CapBAC 拒**（证明权限是 ezagent 方式、真生效）。
- 不变式测试：`owner==nil ⟺ status==:unassigned`。
- **全 gate 绿**：`compile --force` / `arch.scan` / `doc.scan` / **`uri_query.scan`** / `check_invariants(+lifecycle)` / `format` / `test` / `:ezagent_plugin_check`。

## 7 · Discuss-first vs Deferred（开放问题已拍板）
- **已定（用户 2026-06-22）**：① stage 6 态作分类（非权限边界）；② status 收 4 态（细状态 handoff 给工具）；③ **CapBAC = admin + 每个节点的 owner（=认领人，`data_owner` 返回 node.owner）**——一个 owner 概念、最简、纯 ezagent；④ metrics.current 先 `set_metric` 手动，自动同步留后续。
- **Deferred（带目标）**：
  - world 里的导图编辑面（A-full）→ 后续、需 world-coordination §5 登记。
  - Miro 把 status/owner 映射成节点颜色/tag → 增量4下半。
  - **细状态 handoff 给工具**（github PR review/CI/merge）+ artifact/metric 由对应插件**经 dispatch `attach_artifact`/`set_metric` 自动同步** → 各工具插件后续（架构已支持，零耦合）。
  - **Miro 入站**（人在 Miro 改→回 ezagent）：feishu 靠 WS 长连（无需公网），**Miro 无服务端长连** → 起步用**轮询**(GET mindmap_nodes + diff，无需公网)，实时再上 Tailscale Funnel webhook → 增量4下半。
- **Never deferred**：schema + 认领/状态/CapBAC 本体、gates、不变式。

## 8 · Conflict-avoidance / Merge model
- 纯后端、只改 `apps/ezagent_plugin_mindmap/`（+ 可能 arch_baseline_manifest 的 set_effect_sites/doc 计数，按法定 `# arch-cap-bump` 走）。不碰 world / core 逻辑。
- per-task 分支（若并入团队节奏）；当前在 `feat/df-tech` 上做，rebase on main。

## 9 · Gates / 估算 / 开放问题
- 文件：改 `behavior/mindmap.ex`（+~120 LOC，新动作）、`mindmap_test.exs`（+认领/状态/CapBAC 用例）、新增 `node_model_test.exs`（不变式 + e2e）。
- **开放问题（你定）**：① `stage` 取值这 6 个够吗？② status 5 态够吗（要不要 `:review`）？③ CapBAC 粒度（owner-或-admin vs 按 stage 分角色）？④ metrics 的 current 谁来更新（手动 set_metric / 后续自动拉）？
