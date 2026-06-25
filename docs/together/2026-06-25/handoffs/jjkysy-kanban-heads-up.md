# Heads-up — kanban 合并进度 + re-scheme（致 jjkysy / 姚升悦）

> 你在等 kanban(#964) 合 main。诚实同步：**会合，但要先 re-scheme + 等一个前置地基**。你的工作不白费——下面讲清保留什么、改什么、在哪看进度、这期间做什么。

## 1. 结论先说
- **#964 是好工作**（CI 绿、e2e 跑过、架构 review 4 大 invariant 全过）。
- **但不会以 resource:// Kind 形态合 main**：`resource://` 文档语义是"纯 FS 数据引用、非活 Kind"，#964 把它重载成承载活 Kind，与该语义 + "resource=统一 FS 封装"长期愿景冲突（lead 拍板）。
- **kanban 改为 agent**：role `kanban-manager` × flavor `native`（agent=actor，不限 LLM）。board 走 Kind snapshot（不用文件），`resource://` 回归纯 FS。

## 2. 你的工作 100% 保留，只是搬家
- `Behavior.Kanban` + `Connectors` + 24 个动作 + per-node CapBAC + `Kanban.tsx`/`KanbanCanvas.tsx` UI + snapshot 持久 —— **全部保留**。
- 变化：这些 behaviors 从 kanban Kind **搬进 `kanban-manager` role recipe**；UI 的后端 dispatch 目标从 resource:// Kind 换成 kanban-manager **agent**（`entity://agent/.../behavior/kanban/<action>`）；world 读模型从 list-by-Kind-type(:kanban) 改成 **list-by-role**。

## 3. 前置依赖：role 物化地基（lead/codex 在建）
kanban-as-role 依赖一个还没建好的地基（#54 的后续）。设计已收口在 **`docs/together/2026-06-25/specs/role-foundation-design.md`**（已在 main）：① per-instance behavior mount/detach ② role=recipe（code-seed/roles_0/template）③ create 经 lifecycle 应用。**这块核心由 lead/codex 建**（深核心、高爆炸半径，不是 kanban 领域）。

## 4. 这期间你做什么
- **主任务继续**：你今天本来的 **dev-together skill 改进**（你 owner，没被 block）。
- **小贡献（你最懂 kanban）**：(a) 起草 **kanban-manager 的 recipe**——列出它的 behaviors / requested_caps / skills（从 #964 现有 kanban 提取）；(b) **作为消费者评审** role-foundation spec，确认地基能支撑 kanban 的需求（有缺口提出来）。
- **地基落地后**：由你做 **kanban-as-role re-scheme**（定 recipe + 删 Plan-B + 重接 world + board snapshot）——这是你的功能本体。

## 5. 在哪看进度 + 设 /loop
- **kanban 你的基座**：**draft PR #985**（branch `integration/kanban` = rebased #964 + kanban-as-role spec）。**这是你的根据地。**
- **kanban-as-role spec**：`docs/together/2026-06-25/specs/kanban-as-role-spec.md`（在 #985 分支上）。
- **role 地基进度**：spec 在 main（上面路径）；地基的实现 PR 会陆续出现（关注 role-foundation 相关 PR / 群里同步）。
- **任务登记**：`docs/futures/todo.md` 的"Role-materialization + kanban-as-role"两条。
- **设一个 `/loop`（定时自驱）**：每隔一段
  1. 把 `integration/kanban`（#985）**rebase 到当前 main**（main 在动，A2-A6 等会陆续合，保持你的基座新鲜，将来好合）；
  2. 查 role 地基是否已合；
  3. **role 地基一合，就开工 kanban-as-role re-scheme**（按 spec）。

## 6. 兼容性提醒（让将来合得干净）
- **别再加深 `resource_kinds/0` / `ResourceKindRegistry` 依赖**——它们要删。
- **board 继续用 snapshot**（已是），别引入文件持久。
- 把 kanban behaviors 维持成**一个干净、易抽出的集合**（将来直接进 recipe）。
- 触及 world 区与 gagameow(console)/zhaomaota97(hello) 按 `docs/guide/world-coordination.md` 协调。
