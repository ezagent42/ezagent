# mindmap 三处纠正：状态保存反馈 / 编辑器+文件附件 / stage 顺序约束

> 实证基准：代码 worktree `df-tech`，PRD worktree `ezagent-yao/docs/discuss/df-prd/`。
> 应然以 `07-定版-自举开发流程-10分钟.md` + `07-demo-接力链-多角色视角.html` + `03-思维导图.md` 为准。
> 结论一句话：问题1是纯 UX 反馈 bug（持久化没问题）；问题2 ezagent 已有完整文件上传子系统，excalidraw 该走它；问题3 当前 R1 太弱，07 把 9 阶段当固定接力链，stage 不该自由设。

---

## 问题1：改节点状态"没地方保存"

### 现状（不是持久化 bug，是反馈 bug）

链路是通的、状态**确实落库且跨重启存活**：

- 前端 `Mindmap.tsx:219` 状态下拉 `onChange` → `onAction("mindmap.set_status", {...args, status})`
- world dispatch `mindmap_actions.ex:46-51` → `Invocation.dispatch` 打到 mindmap Kind（P14 合规）
- behavior `behavior/mindmap.ex:340-354` `handle_set_status` → `update_node` → `commit/1` = `{:set, :tree, tree}`（唯一 set 字面，`:447`）
- Kind `mindmap.ex:33` `persistence: {:snapshot, :on_change}` —— **每次 `{:set}` 落核心 KindSnapshot，冷启动 SpawnRegistry rehydrate**。所以 Kind 重启后状态还在，不是丢。

动作成功后 `mindmap_actions.ex:107` re-read 整棵树 + `push_event("world:state")` 推回前端，UI 会刷新成新状态。

**真正的问题在前端 UX**：`Mindmap.tsx:219` 那个 `<select value="">` 是**受控且永远绑死空串**——每次 onChange 触发动作后，select 立刻被 React 重置回 placeholder「状态…」，下拉框**不显示当前 status**。当前 status 只在上面 `:201` 一行小字（`STATUS_ICON + status`）里出现。用户的体感是"我选了 doing，下拉框又变回『状态…』了，是不是没存住？"——其实存住了，只是控件没回显，也没有"已保存"的瞬时反馈。

→ **判定：无持久化 bug。是「下拉不回显当前值 + 无保存反馈」的 UX bug。**

### 07/原型的应然

- 03 §4.2「每个节点都有主」：状态机 `待分配→已认领→进行中→已闭环`（对应 `unassigned→claimed→doing→done`），验收信号是"导图里不存在既没认领也没标待分配的灰色节点"——要求**节点状态在图上一眼可见**，即状态必须清晰回显，不是藏在一行小字里。
- 07 prototype `gateVerdict`（`MindmapCanvas.tsx:53`，前端已实现软门）：done 状态触发"本棒已过 gate"。状态是 gate 判据的输入，**改完要立刻看到状态 + gate 评价变化**才闭环。
- 07/03 没有"显式保存按钮"的设计——交互是即时的（选了就生效）。所以不需要加 Save 按钮，需要的是**即时回显 + 成功反馈**。

### 落地建议（问题1）

1. **下拉回显当前值**：`Mindmap.tsx:219` 把 `value=""` 改成 `value={node.status ?? ""}`，去掉空 option 仅作 unassigned 占位（unassigned 不在 `@settable_status`，保留 placeholder 但默认选中当前 status）。stage 下拉 `:223` 同理改 `value={node.stage ?? ""}`。
2. **保存反馈**：底部已有 `Status` 组件读 `last_dispatch_status`（`:313`，"ok"/"error:..."）。可在 NodePanel 内对刚改的字段加一个短暂的 ✓ 或 inline「已保存」micro-feedback（2s 后消失），明确告诉用户落库成功。
3. v1 必做：1（回显）；v1 建议：2（反馈）。都是纯前端改动，不动 behavior/持久化。

---

## 问题2：markdown 该是编辑器；excalidraw 等文件放哪

### 现状

- inline 内容（spec 卡 / Gherkin）当前用 `window.prompt` 单行输入（`Mindmap.tsx:268-271` 加内容、`:256-259` 加链接、`:282-286` 设指标）。`window.prompt` 是单行、无 markdown、无多行——对 Gherkin/spec 卡这种多行结构化内容是临时 hack。
- inline 内容存进 artifact 的 `content` 字段，behavior 端 `cap_content` 截断 8192 字符（`behavior/mindmap.ex:503,515`），进节点快照=真相源（注释明说"CI 关键内容走 inline 而非外部 ref，防飞书死链"）。这条**设计方向是对的**：spec 卡/Gherkin 该 inline 进真相源。
- **文件类附件（excalidraw/图片/PDF）当前没有路径**：artifact 只有 `tool/kind/ref/url/content` 五字段，url 靠用户手填外链。没有"上传文件→挂节点"的能力。

### ezagent 已有完整文件上传子系统（关键发现）

mindmap **不需要新造**文件存储，world 已有一套 workspace 分区、cap 鉴权、签名下载的上传栈：

- 存储：`Ezagent.Uploads`（`ezagent_core/lib/ezagent/uploads.ex`）—— 地址 `resource://<ws>/uploads/<name>`，字节落 `Home.path("uploads")/<ws>/<name>`（**ws 分区**，`:7-9`）。经 hardened `FsResolver` 解析，鉴权携带（resolve 要求 caller 认证过的 `scope.workspace`，`:56-69`）。`store_upload!/3`（`:115`）生成 `<uuid>-<sanitized>` 防撞名。
- 上传端点：`POST /world/uploads`（`world_uploads_controller.ex`）—— multipart，dispatch `:session :attach` 在 Kind chokepoint 鉴权（`:119-141`，跟 `:send` 同闸，co-grant），存到目标 session 的 workspace，返回 `{uri, name, size, grant}`。grant 是签名的 `uri↔caller↔session` 防洗（`:150`，Phoenix.Token + TTL）。
- 前端 parity：`Conversation.tsx:250-296` `uploadFiles` 已经在用这个端点（`fetch("/world/uploads")`），pending 附件带 grant，下条消息 `chat.send` 时 `build_message/3` 验 grant 后嵌 URI。
- 下载：server 渲染 attachment 时给 uploads URI 配**签名 href**（`Conversation.tsx:13` 注释、`message_row/2`）；非 uploads 值渲染成纯 label。

### 07/03 的应然

- 03 §5.2「产物挂载」验收：MVP 跑通 GitHub + 飞书两挂载来源，"在任一外部工具产出后，节点页能点进去看到该产物"。
- 03 §6.6「excalidraw/xmind/obsidian connector」：**明确把 `.excalidraw` JSON 文件、`.xmind` 文件的「文件路径/id」当产物挂节点**，"附件下载复用 socialware 客户面"（`A-ezagent能力盘点.md:174`）。验收："一个 excalidraw 图能挂到具体开发节点并从节点点开"。
- 07 表 §5「体验主张」工具列 = `excalidraw`，§6 spec 卡 = inline 文本（markmap/飞书 docx）。
- 所以应然分两类，**07 已经分清**：
  - **结构化文本**（spec 卡 / Gherkin / 价值卡）→ inline content 进真相源（当前 artifact.content 方向对，缺的是编辑器）。
  - **文件**（.excalidraw / 图片 / PDF）→ 当作上传文件挂节点，存 ezagent uploads，节点存其 `resource://<ws>/uploads/...` URI + 签名 href，"从节点点开"。

### 文件附件存哪——结论

**存 ezagent 自己的 uploads 子系统**（`resource://<ws>/uploads/<name>`，ws 分区 + cap 鉴权 + 签名下载），**不存外部、不靠用户手填外链**。理由：
1. 03 §6.6 明说附件下载"复用 socialware 客户面"——就是这套签名 href 机制。
2. 03 §6.1 钦定"真相源在 ezagent 库，外部工具数据是副本"——excalidraw 文件作为产物副本挂回，应落 ezagent 存储，不依赖外链死链（跟 inline content 防飞书死链同逻辑）。
3. 基础设施已存在且经过 P2b 加固，复用零新增攻击面。

唯一缺口：现有 `/world/uploads` 端点 dispatch 的是 `:session :attach`，绑 session。mindmap 节点挂附件需要一条**对应的上传授权路径**——要么复用同端点但把鉴权目标改为 mindmap Kind 的某个 cap（如 `:attach_artifact`），要么新加 `mindmap :attach` 授权 + 一个挂载动作把返回的 uploads URI 写进 artifact。这是 v1.5 的一块小工程（鉴权+存储已现成，只差把"上传产物"接到 mindmap 的授权链）。

### 落地建议（问题2）

- **markdown 编辑器**（替 `window.prompt` 加内容）：用轻量内联 markdown 编辑器。选型建议 `@uiw/react-md-editor`（带预览、体积小、受控）或更轻的 `react-simplemde-editor`；若不想加依赖，先用一个多行 `<textarea>` + 等宽字体过渡（比 prompt 强很多，零依赖）。内容仍走现有 `attach_artifact` 的 `content` 字段（8192 上限够 spec 卡/Gherkin）。**v1 必做：textarea 多行编辑**；v1.5：换成带预览的 md 编辑器。
- **文件附件**（excalidraw/图片/PDF）：复用 `/world/uploads` 上传栈，新增一条 mindmap 授权 + 把 uploads URI 写进节点 artifact（`tool: "upload", kind: "file", url: <签名href或resource uri>`）。NodePanel 加一个「上传文件」按钮（`<input type=file>`，parity `Conversation.tsx` 的 fileRef）。**这块 v1.5 后置**（鉴权接线是真工程），v1 先支持「加链接」手填外链占位。
- 优先级：v1 = textarea 编辑 + 手填外链；v1.5 = md 编辑器 + uploads 文件挂载授权打通。

---

## 问题3：节点之间有前后关系，不能随意改 stage

### 现状（R1 太弱）

当前 R1 = "子 stage ≥ 父 stage" 的单调约束，**约束内仍允许自由改 stage**：

- `behavior/mindmap.ex:266-287` `handle_set_stage`：`parse_enum` 校验是合法阶段 → `stage_fits?` 检查 `父 stage ≤ 自己 ≤ 每个子 stage`（`:293-306`）→ 通过就 `update_node` 自由设。
- `handle_move_node`（`:235-238`）移动时也只查 `node.stage ≥ 新父 stage`。
- `add_node`（`:202-203`）：根默认 `:positioning`，子默认**继承父 stage**。

即 R1 只保证"沿父子链 stage 单调不回退"，但**没有把 stage 钉死到结构**——同一个父下两个子可以一个 `:pain` 一个 `:pr`，用户能在 `[父,子]` 区间内任意手改 stage。

### 07/03 的应然——9 阶段是固定接力链，stage 由"棒次"决定

07 把 9 阶段建模成一条**固定线性接力链**，这是 load-bearing 模型：

- `07-定版.md` 流程总图：`定位→北极星→痛点→认领映射→线框→功能spec卡→issue→测试→PR`，**每个箭头 = 一次真相源交接 = 一道 gate（上一件不合格不放行）**。
- prototype `07-demo.html:204-232` `NODES` 数组 = 9 个固定节点，**id 1..9 就是棒次/顺序**；`GATES`（`:235-244`）键是 `'1-2'..'8-9'`，**只有相邻棒次之间有 gate**——顺序是模型本身，不是可选属性。
- 每棒 owner 固定（`ROLES[].owns`，`:194-198`）：1,4=产品负责人 / 2=运营 / 3,5,6=产品 / 5=设计 / 6,7,8,9=研发。stage 决定谁认领（03 §3.2 岗位↔层映射）。
- 03 §3.2 验收"每个第一层分支都至少有一个岗位认领（无悬空分支）"+ §2.1 验收"每个开发节点都能往上追到它服务的痛点（树连通无孤儿）"——**节点在链上的位置（属于哪一棒）是结构事实，不是用户随手填的标签**。

关键差异：**07 的 9 阶段不是节点的自由属性，而是节点在接力链里的"棒次"**。一个节点属于哪一棒，由它服务的上游 truth 决定（功能卡接线框、issue 接功能卡…）。"前后关系"指的就是**棒次间的 gate 依赖：第 N 棒的产出（truth）是第 N+1 棒的唯一输入，上一棒没过 gate，下一棒不放行**。

### "前后关系"的确切约束

1. **跨阶段单调（链方向）**：子树沿父子链 stage 单调不回退（已有 R1，保留）。这对应"深入只能往后"，07 的"issue 后不能插 feature"（feature(5)<issue(6)）。
2. **gate 依赖（前置完成）**：第 N+1 棒进入「进行中/已认领」前，第 N 棒（其上游 truth 节点）应已过 gate（done + gate pass）。当前 `gateVerdict` 只是软提示不拦（`MindmapCanvas.tsx:51` 注释"不拦 status，纯提示"），**07 的应然是硬 gate**（"上一件不合格不放行"）。
3. **stage 不应自由手改**：节点的 stage 应由其在链上的结构位置推导/约束，而非用户在 `[父,子]` 区间内任意选。理想是 stage 跟"它接的是哪一棒的 truth"绑定。

### R1 该怎么加强

R1 当前只做了约束(1)的一半，缺(2)(3)。建议分级加强：

- **R1.1（v1，收口自由改）**：`set_stage` 不再允许在 `[父,子]` 区间内任意跳。改为**只能改成「父 stage」或「父 stage 的下一棒」**（即 `parent_stage` 或 `parent_stage+1`），把"子节点是父的同棒或下一棒"钉死，杜绝同父下子节点 stage 乱序。根节点固定 `:positioning` 不可改。
- **R1.2（v1.5，gate 前置硬化）**：把 `gateVerdict` 从软提示升成**进 status 的前置闸**——节点要进 `doing`，其父链上一棒必须 `done` 且 gate pass。对齐 07「上一棒不合格不放行」。这要在 `handle_set_status` 里加跨节点检查（读父节点/上游 truth 节点状态）。
- **R1.3（v2，泳道/棒次视图）**：07 prototype 是横向 9 列接力链（按棒次分列）。当前 `MindmapCanvas` 是树视图。可加一个**按 stage 分列的泳道视图**，让"哪一棒、前后关系"在画布上结构可见——但这是可视化增强，不是约束本身，后置。

注：07 没有"同阶段内顺序"或"任意跨阶段依赖"的概念——前后关系**只沿固定 9 棒链 + 父子树**，不是 DAG。R1 不需要做成通用依赖图，只需把"棒次单调 + gate 前置"两条钉死。

---

## 三问落地优先级汇总

| 问题 | v1 必做 | v1.5 | v2 |
|---|---|---|---|
| 1 状态保存 | 下拉回显 `value={node.status}`（纯前端，非 bug 修复是 UX） | inline「已保存」反馈 | — |
| 2 编辑器+文件 | textarea 多行编辑 + 手填外链占位 | md 编辑器 + uploads 文件挂载授权打通 | — |
| 3 stage 顺序 | R1.1 收口自由改（只能父棒或下一棒） | R1.2 gate 前置硬化 | R1.3 棒次泳道视图 |
