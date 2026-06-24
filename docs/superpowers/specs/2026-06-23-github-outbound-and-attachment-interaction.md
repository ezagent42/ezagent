# GitHub 出入站 + attachment 交互设计

> 调研基线 worktree `df-tech` @ `98ebc0ee`（点1/2/3 + 点4 已落地）。每条判断附 `file:line` 实证。
> 大白话总纲：**GitHub 该走 Miro 那条（插件自有出站连接器），不该做成飞书那样的完整插件**。下面逐条论证。

---

## 1. 为什么飞书是完整独立插件，Miro 只是出站连接器？

### 飞书比纯出站连接器多扛四样东西（缺一不可）

| 能力 | 飞书有 | 纯出站连接器（Miro/MiroSync）没有 | 实证 file:line |
|---|---|---|---|
| **入站 webhook 接收** | 整条 HTTP/WSS 入站链路 + 唯一一条对 ezagent_web 的路由侵入 | 没有入站 | `apps/ezagent_web/lib/ezagent_web/router.ex:181`（`forward "/api/feishu/webhook"`）；`webhook_plug.ex:31,84`；`event_decoder.ex:37`；`inbound_dispatcher.ex:58` |
| **身份绑定** | 把飞书侧陌生身份（open_id）翻译成 ezagent 身份 + 解 caps | 不需要：出站方向 caller 身份内核现成给 | `user_binding.ex:30,86`；`sender_resolver.ex:40,55-80`；`binding_policy.ex:61` |
| **session 路由（注意：不是创建）** | chat_id → session_uri 反查 + 多绑定歧义消解 + 冷会话 rehydrate | 不需要 | `inbound_chat_lookup.ex:142,170`；`inbound_dispatcher.ex:228-246` |
| **external_mirror adapter 注册** | 实现统一出站域的 Adapter+Binding 契约（`:push` KIND） | 不走统一域，是插件自有 GenServer | `feishu_adapter.ex:76`；`feishu_chat_binding.ex:48`；`application.ex:120` |

**精确修正**：飞书**不创建 session**。它只 `SpawnRegistry.spawn`/`ensure_live` 把已经持久存在的 User Kind（`sender_resolver.ex:70`）和 Session Kind（`inbound_dispatcher.ex:229`）拉活。全插件 grep 不到任何 `Sessions.create`。所以"完整插件"多出来的不是"创建会话"，而是"**把一条陌生的入站消息正确路由到一个已存在的会话**"——这套身份解析 + 反查 + 歧义消解 + 唤醒逻辑，是纯出站连接器完全不需要的。

### 判定标准（P9 / P12 / P13 角度）

用一句话概括 ezagent 的判定规则：**有没有"陌生入站"决定要不要做成完整插件**。

- **P13（Phoenix 是 transport 不是 fullstack）**：只有需要"接收外部世界主动打进来的 HTTP/WSS"时，才需要在 Phoenix 上挂一条入站路由（飞书占了 `router.ex:181` 这一条）。纯出站不碰 Phoenix 路由。
- **P12（adapter pattern：协议特定代码只在 adapter 里）**：飞书把协议特定的入站解码（`event_decoder.ex:37`）、出站翻译（`feishu_adapter.ex:207` 的 `event_to_payload/1`）都关在自己插件里。GitHub 同理——GitHub REST 的细节只该待在 GitHub 连接器内部。
- **P9（"读什么数据"决定归属层）**：出站连接器读的是真相源（节点树/会话 slice）然后往外推，它**不拥有任何内核数据**，所以放插件层最合适，不用动 domain 层。

**判定表**：

| 这个集成需要…… | →做法 |
|---|---|
| 外部世界主动打进来（webhook / 长连接），且要把陌生身份翻译成 ezagent 身份、路由到会话 | **飞书式完整插件**（入站链路 + 身份绑定 + session 路由） |
| 只把内核真相源的数据推出去，回写也只是己方轮询比对（非破坏入站） | **Miro 式纯出站连接器**（插件自有 GenServer，真相源永远是 ezagent） |

---

## 2. external_mirror 域是什么、跟 session 绑死了吗？

### 结论：死死绑在 session 上，不支持 resource-scoped 出站。memory 里"锁死 session 域"的判断**现在依然成立**。

逐层实证（每一层都把"源"写死成 session，缺一不可绕过）：

| 层 | file:line | 硬绑点（大白话） |
|---|---|---|
| DB 投影行 schema | `binding_row.ex:43` | 字段名直接叫 `session_uri`，没有通用的 `source_uri`。自然键是 `(session_uri, adapter_id, target_id)`（`binding_row.ex:13-19`） |
| Worker 的 URI 派生 | `worker_spawn.ex:220` | 函数头 guard 写死 `%URI{scheme: "session"}`，传任何非 session 的 URI 进去直接崩 |
| 订阅源 | `external_mirror_worker.ex:282,876` | Worker 订阅的是 Session 的 Publisher 事件流（`subscribe_from` 打到 `session_uri`） |
| Publisher 实现者 | `publisher.ex:20-30` | Publisher 契约 V1 的**唯一实现者就是 Session** |
| 授权 cap 轴 | `external_mirror.ex:187-193,747-749` | required_caps 全是 `cap(:session, ...)`，`data_owner/1` 只认 `scheme: "session"` |
| 连 pull 路径都绑 | `adapter.ex:264` | `render(session_uri, ctx)` 第一个参数就写死是 session_uri |

**对 mindmap 节点出站的判断**：一个 mindmap 节点是 resource（URI 类似 `resource://mindmap/...`，不是 session）。要让它走 external_mirror 出站，缺口有三类：
1. **它得先变成 Publisher**（实现 `subscribe_from/3`、`snapshot/1` 等），但目前 Publisher 只有 Session 一个实现者。
2. **scope 全链路写死 session**，要泛化成 `source_uri :: URI.t()` 是架构层改动，不是配置层。
3. **语义错配**：external_mirror 是"**状态镜像**"模型——把源的 slice 变更持续幂等地同步成一个外部对象（`adapter.ex:9-14`，worker 还有 `last_published_send_key` 去重，`external_mirror_worker.ex:667-684`）。而"建一个 GitHub issue"是**命令式单次出站**，跟"持续镜像最新状态"这个范式不吻合。

**这正是 Miro 当初改自研 MiroSync 的原因**——`apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro_sync.ex:11-12` 注释直接写明："plugin 自有进程，**不复用 session 锁死的 external_mirror 域**"。GitHub 应当沿用同一判断。

---

## 3. 用户旅程 → GitHub 要不要入站？

旅程拆解：
1. 用户在 mindmap 会话里 claim 一个开发节点（`behavior/mindmap.ex:272` `handle_claim_node`）。
2. 可能在**别的会话**实际开发、提交代码（这一步在 ezagent 之外）。
3. 回 mindmap 会话给该节点挂 issue/PR attachment（`behavior/mindmap.ex:320` `handle_attach_artifact`，artifact schema = `%{tool, kind, ref, url}`，`mindmap.ex:18` 注释明说就是给"github PR/飞书文档"用的）。
4. 同步到 GitHub 做 CI。

**GitHub 需要入站吗？** 看是否要把"CI 结果 / PR merge 状态"回写到节点。

- **MVP（推荐先做）= 纯出站**。复用 MiroSync 的"非破坏轮询"范式（`miro/sync.ex:138-163` 的 `detect_inbound` 就是纯函数、只读对比、真相源永远是 ezagent）。GitHub 状态用**插件自有 GenServer 定时轮询** GitHub API 拉 PR/CI 状态，比对后**只更新节点的 artifact 字段**（往 `metrics` 或 artifact 上挂个 `ci_status`），不走 ezagent 入站 dispatch、不碰 webhook、不碰 Phoenix 路由。这跟旅程完全契合：用户主动挂 attachment（出站建 issue），系统轮询回填状态（伪入站，纯轮询）。
- **真正需要 webhook 入站的场景**只有一个：要"GitHub 上发生事件**实时**反向触发 ezagent 里的某个 dispatch/通知"（比如 PR 被 merge 立刻在会话里 @人）。这才需要飞书式的 `router.ex` 入站路由 + 身份映射。**旅程里没有这种实时反向触发的硬需求**——挂 attachment 是用户主动行为，CI 状态轮询能接受秒级延迟。

**判定：GitHub 走 Miro 式纯出站连接器**（出站建 issue/PR + 轮询回填状态），不做飞书式完整插件。

---

## 4. attachment 交互设计

### 4.1 attachment → 单独发送到 chat（复用已做的卡片机制）

已有的 mindmap 卡片机制（点4）是这样工作的，**纯前端、零后端改动**：

- 分享按钮：mindmap 子视图里点"分享到对话"→ `onShare` → 复用现有 `onSend` 发一条带 sentinel 前缀的 chat 消息。sentinel = `[[mindmap]]`（`Conversation.tsx:9` 定义 `MINDMAP_CARD_TAG`，`Conversation.tsx:417` 触发 `onSend(sessionUri, "[[mindmap]] 思维导图", [])`）。
- 气泡识别：聊天气泡渲染时，若 `message.text` 以 sentinel 开头，就渲染成可点卡片（Network 图标 + "点击编辑 →"），点击 `onSwitchView(sessionUri, "mindmap")` 跳回编辑（`Conversation.tsx:461-474`）。

**把一个 attachment 做成可点 chat 卡片**：照搬这套，给 attachment 定义新 sentinel + 携带 ref。建议：
- 新 sentinel，例如 `[[artifact:github_pr]]`，后面跟 artifact 的 `ref`/`url`。在节点属性面板的 attachment 列表项上加一个"发到对话"按钮，调 `onSend(sessionUri, "[[artifact:github_pr]] #1234 标题", [])`。
- 在 `Conversation.tsx:461` 那个 sentinel 分支里加一条 `else if startsWith("[[artifact:")`，渲染成带 GitHub 图标的卡片，点击行为是**打开外部 url**（`window.open(artifact.url)`）而不是 `onSwitchView`——因为 attachment 指向的是外部对象，不是内部视图。
- 关键点：**sentinel 机制是字符串前缀约定，纯前端**，不需要任何 behavior/domain 改动，扩成本极低。

### 4.2 出站怎么交互（数据从节点真相源流到 GitHub）

参考 MiroSync 的 `sync_or_bind` 模式（`miro_sync.ex:54-66`）：
- 前端在节点/会话里点"出站到 GitHub"→ world 的 `handle_dispatch(socket, "mindmap.sync_github", ...)`（照抄 `mindmap_actions.ex:82` 的 `mindmap.sync_miro` 子句）。
- world 调 `EzagentPluginGithub.GithubSync.create_or_sync(node_uri, ...)`（照抄 `mindmap_actions.ex:119` 调 `MiroSync.sync_or_bind` 的写法）。
- GithubSync（插件自有 GenServer，结构照 `miro_sync.ex:18` 的 `use GenServer`）读节点真相源 → 调 GitHub REST 建 issue/PR → 拿回 issue url。
- **数据流**：节点（resource 真相源，`behavior/mindmap.ex` 的 tree slice）→ 读出 → GitHub API → 回 issue。出站连接器**只读真相源不拥有数据**（P9），跟 Miro 出站完全同构。
- 建好后**把 issue 回挂成节点 artifact**：dispatch `mindmap.attach_artifact`（`mindmap_actions.ex:53`，artifact = `%{tool: "github", kind: "issue", ref: "#123", url: "https://github.com/..."}`），形成闭环——出站结果变成节点上的可见 attachment。

### 4.3 出站结果怎么回到 session 显示/通知

照搬 `mindmap_actions.ex:120-127` 的 `sync_miro` 回路：
- 出站成功后，world 的 LiveView `push_event("world:state", %{...})` 把结果（如 `github_issue_url`）推回前端 socket，前端 assign 后渲染（Miro 现在就是这样推 `miro_board_url` 的，`mindmap_actions.ex:124-126`）。
- 进一步**通知到会话**：出站成功后顺手发一条卡片消息——用 4.1 的 sentinel 机制 `onSend(sessionUri, "[[artifact:github_issue]] #123 已创建", [])`，会话里就出现一张可点卡片（点击打开 GitHub）。这条消息走的是正常的会话 send 路径，会话里所有人都能看到。
- 这样回 session 有两层：**即时反馈**（push_event 改当前用户的 UI）+ **持久可见**（发一条卡片消息进会话历史，所有成员可见）。

---

## 结论建议

### GitHub 做成哪种？→ Miro 式纯出站连接器

理由收口：
1. **旅程不需要实时反向 webhook**——挂 attachment 是用户主动出站，CI 状态用轮询回填即可（接受秒级延迟）。没有"陌生入站"就不需要飞书那套入站链路 + 身份绑定 + session 路由。
2. **external_mirror 域死绑 session，且是状态镜像范式**，跟"resource 节点出站 + 命令式建 issue"双重错配（见 §2）。强行复用要改架构层，得等 Allen。
3. **MiroSync 已经趟出可复制的纯出站连接器范式**（插件自有 GenServer + `sync_or_bind` + 非破坏轮询 + 真相源恒为 ezagent），GitHub 照抄即可，无需动 core/domain。

**具体形态**：新建 `apps/ezagent_plugin_github/`，内含 `GithubSync`（GenServer，仿 `miro_sync.ex`）+ `Github`（REST client，仿 `miro.ex`）+ `Github.Sync`（纯函数树/节点→issue payload，仿 `miro/sync.ex`）。world 侧加 `mindmap.sync_github` dispatch 子句（仿 `mindmap_actions.ex:82`）。**不碰 ezagent_web 路由、不碰 external_mirror 域、不碰 core**。

### attachment 交互落地路径（三步，纯前端为主）

1. **attachment → chat 卡片**：扩 sentinel 约定（新增 `[[artifact:*]]` 前缀），在 `Conversation.tsx:461` 的 sentinel 分支加一条，点击打开外部 url。纯前端，零后端改动（§4.1）。
2. **出站交互**：节点面板"出站到 GitHub"按钮 → world `mindmap.sync_github` dispatch → `GithubSync.create_or_sync` 读节点真相源 → 建 issue → `attach_artifact` 回挂（§4.2）。
3. **回 session**：`push_event("world:state")` 即时反馈 + `onSend` 发卡片消息进会话历史让所有成员可见（§4.3）。

**关键收益**：artifact schema（`%{tool, kind, ref, url}`，`behavior/mindmap.ex:18`）和卡片 sentinel 机制（`Conversation.tsx:9`）都已就位，GitHub 集成是"填空"而非"造新地基"。
