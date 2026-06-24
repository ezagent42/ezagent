# df-tech 三道设计题：双向冲突 / CI gate / 数据存哪

> 写于 2026-06-23。研究员视角，全部带 file:line 实证。
> 真相源 = ezagent（mindmap domain，SQLite）；Miro / GitHub / 飞书 = 出站投影 + 入站事件。

---

## 问题1：双向编辑冲突怎么处理？飞书怎么解决 message edit？

### 1.1 飞书入站：根本不存在"回写已有状态"这回事

飞书插件的入站**只触发 dispatch，从不更新任何 ezagent 侧的持久状态**。一条入站消息走的路是：

- `webhook_plug.ex:69` `handle_event/2` 只认 `%{"message" => msg, "sender" => sender}` 一种事件形状，其它形状（line 93）直接 `Logger.debug` 丢掉。
- `event_decoder.ex:37` `build_body/1` 按 `message_type`（text/image/file/audio/media）翻成 `%{text, attachments}`，**没有 `message_changed` / `recalled` 这些 edit 类型的分支**——飞书的消息编辑事件根本不在它订阅/处理的 case 里。
- `inbound_dispatcher.ex:58` `dispatch/1`：解析发件人 → 查 chat→session 绑定 → `Ezagent.Invocation.dispatch/1` 投进 session（line 299）。终点是"把消息送进会话"，**不是改某个领域对象**。

**所以飞书没有"message edit 回写"的设计，因为它压根不维护可被回写的镜像状态**。入站只是把人说的话送进路由。一条消息编辑过、还是新发的，对它没区别——都是"有人在群里说了话"。

**幂等现状（要点）**：feishu 入站**目前没有**用 `idempotency_key` / `Ezagent.Idempotency.seen?` 去重（`grep` 全 feishu lib 只在一个 migrate task 的注释里出现 idempotency，`inbound_dispatcher.ex` / `webhook_plug.ex` 里零调用）。webhook 重试 = 重复 dispatch = 群里那条话被重复送进会话。这跟 CLAUDE.md 讲的 P22「收到即记」**有缺口**——但对"消息送进会话"这种幂等不敏感的语义影响小，对"改 mindmap 节点"这种**有副作用**的入站就是必须补的（见下）。

### 1.2 Miro 出站现在是单向，`detect_inbound` 干嘛

Miro 侧是**真·单向 + 一个非破坏性入站探针**：

- 出站：`miro/sync.ex:108` `sync_out/2` —— Miro **没有 in-place update API**，所以策略是 `delete_all_nodes` + 按 ezagent 树重建（line 110-115，注释明写"Miro 无 in-place update"）。每次出站都是**全删全建**，ez_id↔miro_id 映射重算。
- 入站探针：`miro/sync.ex:147` `detect_inbound/2` 是**纯函数、只检测"人在 Miro 新加"的节点**（miro_id 不在上次映射里的，line 153）。它**只产 add op，绝不产 delete op**——注释 line 143「Miro 端删除**不**回删 ezagent，下次 sync_out 重建即自愈」。
- 编排：`miro_sync.ex:125` `sync/1` 每 tick 先 `detect_inbound` → 把人新加的节点 `add_node` dispatch 回 ezagent（line 130，走 P14），**再**重读 ezagent 树（含刚入станционные的）→ `sync_out` 全删全建覆盖 Miro（line 133）。

**当前 Miro 冲突模型已经是这样**（代码即文档）：
- 人在 Miro **新加** → 吸纳回 ezagent（add）。
- 人在 Miro **改/删** → **被下一轮 sync_out 全删全建覆盖**，悄无声息丢失。`detect_inbound` 不检测 rename，也不检测 delete。
- ezagent 永远赢。

### 1.3 结论：mindmap 节点的正确冲突模型

**ezagent 赢，是当前实现也是正确的 v1 模型**，理由是 mindmap 已经被宪法级定为单一真相源（`miro/sync.ex:9`、`miro_sync.ex:9` 都写死"真相源=ezagent"）。具体到三种动作：

| 外部（Miro）动作 | 当前行为 | 是否正确 | 备注 |
|---|---|---|---|
| 新增节点 | `detect_inbound` 吸纳回 ezagent | ✅ 正确 | 唯一被尊重的外部编辑 |
| 改标题 | 下轮 sync_out 覆盖（丢失） | ⚠️ 可接受但有损 | v1 不支持外部 rename 回写 |
| 删节点 | 下轮 sync_out 重建（自愈） | ✅ 故意如此 | 防止外部误删污染真相源 |

**能不能借鉴飞书？不能直接借鉴，因为方向相反**：
- 飞书入站是"消息送进会话"，**无副作用、无镜像状态**，所以它可以无脑 dispatch、不管 edit。
- mindmap 的外部编辑是"改一个**有镜像状态**的领域对象"，必须决定 merge 策略。这是飞书没解决也不需要解决的问题。

**真正能借鉴飞书的是两点**：
1. **入站统一走 dispatch（P14）改领域对象**——`miro_sync.ex:130/175` 已经这么做了（`add_node` 经 `Invocation.dispatch`），和 `inbound_dispatcher.ex:299` 同一条铁路。
2. **失败要让人看见**——飞书 `inbound_dispatcher.ex:106-171` 把 cap 拒绝/跨 workspace 拒绝都 react 回群 + 文字解释（Allen「silent down 不可接受」）。mindmap 入站目前是 `detect_inbound` 静默吸纳，**冲突时没有任何"这是建议、人来确认"的回路**。

**如果将来要支持"外部改 = 建议、不自动合"**：在 `detect_inbound` 里扩一个 `detect_renamed`（miro_id 在映射里但 content 变了），产出的不是 `set_node` effect，而是**挂一条 suggestion 到节点 / 通知 owner**，由 owner 决定收不收。这是飞书 react-back 模式的迁移。但**这是 v2，v1 不做**——v1 维持 ezagent 全赢、外部只能 add。

---

## 问题2：CI gate —— 纯出站轮询 vs GitHub Action 反打 inbound

### 2.1 你的设计能不能成立：技术上**完全成立**

你的设计 = ezagent 的 GithubSync **出站**轮询 PR → 读 diff/changed_files → 对照节点 CI 判据 → 在 PR 上 post 非阻塞评论/status。**GitHub REST 三个动作都支持纯出站**（已核查）：

- **读 changed files**：`GET /repos/{owner}/{repo}/pulls/{n}/files`（分页列出每个文件 + patch）。
- **读 diff**：`GET /repos/{owner}/{repo}/pulls/{n}` 带 `Accept: application/vnd.github.diff`（拿整 diff 文本）。
- **post 评论**：`POST /repos/{owner}/{repo}/issues/{n}/comments`（PR = issue，issue 评论端点直接用）。
- **post commit status**：`POST /repos/{owner}/{repo}/statuses/{sha}`，`state` ∈ `success|failure|pending|error`（已 WebFetch 核查 GitHub 官方 commits/statuses 文档确认）——push 权限即可建，sha 取 PR head。

**结论：纯出站（GithubSync 主动 GET + POST）足够做完整的 CI 评价闭环。** GitHub 保持纯出站、ezagent 不需要为此开 inbound HTTP 端点。这跟 D2=软提示天然契合：status 用 success/pending 不卡合并，或干脆只 post 评论。

### 2.2 但这跟 PRD 现有设计**冲突**——必须点出

PRD 把 GitHub 明确设计成**和飞书一样的"出站 external_mirror + 入站 webhook→dispatch"双向插件**，不是纯出站轮询：

- `05-ezagent技术开发计划.md:93`：「GitHub … 自研入站 webhook plugin（PR/issue 事件接回挂节点，走 `Invocation.dispatch/1`）」
- `01-工具选型.md:68`：「入站走 dispatch：GitHub webhook（issue/PR/project 变更）→ `Ezagent.Invocation.dispatch/1`（仿 `inbound_dispatcher.ex:58`）→ 更新对应节点状态，PR 合并 → 节点闭环」
- `03-思维导图.md:183` 验收：「PR 合并 webhook→更新节点状态闭环」

**所以 PRD 默认 = GitHub Action/webhook 反打 ezagent inbound 端点**（更像飞书）。你的纯出站轮询是**另一条路**。两条路的取舍：

| | 方案A：纯出站轮询（你的设计） | 方案B：入站 webhook（PRD 现有） |
|---|---|---|
| ezagent 开 inbound HTTP 口 | 不用 | 要（`forward "/api/github/webhook"`，仿 `webhook_plug.ex:14`） |
| GitHub 配置 | 零（只要个 token） | 仓库要配 webhook secret + 端点公网可达 |
| 实时性 | 轮询延迟（≥interval，类比 `miro_sync.ex:23` 默认 30s） | 准实时（事件推） |
| ezagent 主动性 | 强（按节点 CI 判据**主动评价**，是 ezagent 的逻辑） | 弱（被动接事件，逻辑在 GitHub 侧或回调里） |
| 鉴权/安全面 | 小（只出站，无暴露面） | 大（公网 inbound + 签名校验，feishu `webhook_plug.ex:22` 注释自承"future hardening"还没做签名） |
| 幂等 | 轮询天然幂等（重读同一 PR 状态） | webhook 重试要去重（feishu 现在**就没做**，见 1.1）—— 改节点状态有副作用，**必须**补 idempotency |
| CI 评价逻辑放哪 | ezagent 内（节点判据 = 领域逻辑，干净） | 跨 GitHub Action + ezagent，分散 |

### 2.3 结论与取舍

**你的纯出站方案对"CI gate 评价"这个具体场景更优**，因为：
1. **CI 判据是 ezagent 的领域逻辑**（上游节点 done？diff 在 spec scope 内？Gherkin 覆盖？）——这些数据**本来就在 ezagent 真相源里**（节点 stage/status/artifacts，见问题3）。让 ezagent 主动 GET PR diff 来比对，逻辑内聚；让 GitHub Action 反打，等于把领域判据外包到 CI 脚本，反而散。
2. **D2=软**，不需要 status check 卡合并，没有"必须实时阻断"的硬需求，轮询延迟可接受。
3. **避免开 inbound 端点** = 少一个公网攻击面 + 少一套 webhook 签名校验（feishu 这套现在都还没硬化，`webhook_plug.ex:22`）+ 少一套入站去重。

**但要和 Allen 对齐**：这是**偏离 PRD `05:93` 的"GitHub 双向插件"设计**的。建议口径——
- **GitHub 出站镜像（节点状态→issue/评论）走 PRD 原设计的 external_mirror `:push` adapter**（`05:164`）。
- **CI gate 评价单独走纯出站轮询 GithubSync**（类比 `MiroSync` 那个 plugin 自有 GenServer，`miro_sync.ex:18`），**不开 inbound 端点**。
- 只有当出现"PR 合并 → 自动闭环节点状态"这种**需要准实时、且评价逻辑简单**的需求时，才考虑补方案B 的入站 webhook。v1 的 CI gate 用方案A 够了。

一句话：**纯出站轮询做 CI 评价，技术成立、对 D2 软提示是更干净的选择；代价是偏离 PRD 的 GitHub-as-feishu 双向设计，需 Allen 拍板把"CI 评价"和"状态镜像/闭环"拆成两条不同机制。**

---

## 问题3：数据存哪？飞书/excalidraw 支持吗？

### 3.1 数据模型已经定了：节点存结构 + artifact 存 **ref，不存内容**

mindmap 的节点模型在 `apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex:13-20` 写死：

```
node = %{
  parent_id, title, order,                       # 拓扑
  stage:  :positioning|:metric|:pain|:anchor|:ux|:feature|:issue|:test|:pr,
  owner:  user_uri | nil,
  status: :unassigned|:claimed|:doing|:done,
  artifacts: [%{tool, kind, ref, url}],          # 挂工具产物(github PR/飞书文档/xmind…)
  metrics:   [%{name,target,current,unit}]
}
```

**关键：`artifacts` 字段是 `%{tool, kind, ref, url}` —— 只存"哪个工具 / 什么类型 / 稳定 ref / 打开的 url"，不存富内容正文。** 这正是 `behavior/mindmap.ex:18` 注释说的"挂工具产物(github PR/飞书文档/xmind…)"。富内容（飞书 docx 正文、excalidraw 画板 JSON）**留在外部，节点只挂 ref**。

存储位置：节点树（含 artifacts ref）走 Behavior 契约存进 **ezagent 自带 SQLite 的 KindSnapshot**——`research/B-工具选型调研.md:147` 明写"节点↔认领↔产物真相源用 ezagent 自带 SQLite，走 Behavior + `{:set,key,value}` effect 写"。`behavior/mindmap.ex:6` 印证：读用 `ctx[:read]`、写用 `{:set}`，全经唯一 `commit/1` 收敛。**外部工具里的数据是各自工具的副本，真相源仍在 ezagent 库**（`B:135`）。

### 3.2 PRD 具体用到的飞书/excalidraw 功能 → 接力链阶段对照

接力链 9 阶段固定：`positioning → metric → pain → anchor → ux → feature → issue → test → pr`（`behavior/mindmap.ex:32`）。

| 工具/功能 | PRD 出处 | 对应阶段 | 集成形态 |
|---|---|---|---|
| **飞书 docx**（spec/changelog 文档） | `04:229` `04:263` | feature/pr（写 spec、周报） | 出站镜像，**docToken 当 ref 挂节点**（`04:80`） |
| **飞书 bitable**（多维表，岗位↔层↔工具映射、价值复盘） | `04:263` `04:279` | metric/anchor（映射表、复盘） | **record_id 当 ref 挂节点**（`04:263`） |
| **飞书群机器人**（周报触达） | `04:264` | pr（周报） | external_mirror `:push` 镜到群（`05:174`） |
| **飞书 OKR** | PRD 未实质使用（grep 仅泛指"OKR/北极星"概念，无 OKR API 对接） | — | 不在 v1 范围 |
| **飞书变更订阅入站**（`bitable_record_changed_v1` 等） | `01:78` | 全链路（agent 实时追踪） | **承诺式、R7 标 unverified**（`01:78`），开工先验 |
| **excalidraw 线框/框架图** | `03:107-120` `04:` ux 旅程 | **ux 阶段**（主界面线框、状态机线框、挂载流线框、交互草图） | `.excalidraw` JSON **文件存 ezagent 库，文件路径当 ref 挂节点**（`01:59`） |
| **excalidraw React 组件嵌入** | `01:59` `01:107` | ux（网页出口渲染） | 嵌进 socialware 网页出口（要自研渲染） |
| **mermaid→excalidraw** | `B:72` | ux | agent 先写 mermaid 自动转白板 |

### 3.3 结论：v1 = "节点挂 ref + 出站打开"，**不深度嵌入渲染**

**飞书**：v1 就是**节点挂 ref（docToken / record_id）+ 出站打开**，和 Miro/GitHub 一个模式。
- 出站（推 spec/周报到飞书）= external_mirror `:push`，**复用现成的 `{FeishuAdapter, FeishuChatBinding}`**（`05:159`，已交付）。
- **入站"订阅文档/表格变更"是承诺式、未实测（R7 unverified，`01:78`）**——这条要不要做、是 v1 还是后置，取决于"agent 实时追踪飞书文档改动"是不是 MVP 必须。PRD 自己也标了"开工先验"。**建议后置**：v1 节点挂 docToken ref 够用，"飞书改了 ezagent 实时知道"是增强。

**excalidraw**：
- **画板真相源在外部文件**（`.excalidraw` JSON 存 ezagent 库或文件区），**节点只挂文件路径 ref**——这是 PRD 反复强调的（`01:59`、`01:60`「不要拿协作房做真相源」、`B:73`）。
- **"嵌入渲染"PRD 确实要求**（`01:59` React 组件嵌进 socialware 网页出口让团队在线编辑），但这是 **ux 阶段的网页出口能力，属于"要自研"档**（`03:196` 6.6 connector 自研）。**不是 v1 第一刀**——`06:276` 明写「excalidraw/xmind/obsidian connector 是锦上添花，MVP 先 GitHub+飞书两条最成熟链路」。

**哪些必须 / 哪些后置**：
- **v1 必须**：节点结构 + artifacts ref 存 SQLite KindSnapshot（已有模型，`behavior/mindmap.ex:13`）；飞书 docx/bitable 出站挂 ref（adapter 现成）；GitHub issue/PR ref 挂载。
- **v1 可做、不阻塞**：markmap 渲染（节点树→可点 HTML 嵌网页出口，`B:41`，自研 Node 端管线）。
- **后置（v2/锦上添花）**：飞书变更订阅入站（R7 未验，`01:78`）；excalidraw React 嵌入渲染（`06:276` 明列后置）；excalidraw/xmind/obsidian connector（`03:196`）。

**一句话**：ezagent 真相源**只存结构 + ref，不存/不渲染外部富内容**；飞书/excalidraw 在 v1 就是"节点挂 ref、点开跳外部工具"，和 Miro/GitHub 同一档。PRD 没要求 v1 嵌入渲染——嵌入是 ux 阶段自研、明确后置的增强。
