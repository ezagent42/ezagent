# kanban 未修项修法总结 + 分批实施计划（2026-07-16，skill-1 评审）

输入 = `2026-07-15-kanban-layering-debt.md` 全部未修项 + 遗留（债③ / join 补发 / 规则8）。
每条过 X/Y 拷问（X=用户报的现象，Y=真正要解的问题），修法带 file:line 锚点（全部现读代码核实，HEAD `743ed6178`）。

---

## 一、同 Y 归并分析（先看这个，再看逐条）

| Y（真问题） | 归并的 X 条目 | 一句话 |
|---|---|---|
| **Y1 实时推送环缺失**：session/board 状态变更没有 server→所有相关在线成员的推送 | ⑰ ㉒-① ㉘ ㉞(后半) | 操作方自己有 push_event 刷新，其他人全靠手动刷新。WorldLive 订阅通道**现成**（per-session events topic + per-user Notifications topic），缺的是**发布侧**：membership/mount/kanban-slice 变更时没人往这些 topic 广播 |
| **Y2 新成员 join 拿不到 session 已挂资源的钥匙** | ⑤TODO ⑧TODO ㉜(step1) | `grant_installer_view_caps` 只挂在 install 点，`Mount.reconcile_session_mounts` 只重发已记录 grantee（mount.ex:139-183）。join 流程（session.ex:781 `handle_join`）零补发 hook——view render cap 和 board operate cap 是同一个洞的两张脸 |
| **Y3 plugin 基线 vs sw 增强的职责倒挂** | ⑳ ㉜(step2) | 建板人钥匙/看板 tab 是 **plugin 基线**，assistant 钥匙/团队增强是 **sw 增强**；现实现把增强做成了硬前置（create_board fail-closed 于 assistant 解析）和门控条件（tab 按 sw 安装显隐） |
| **Y4 看板面板/向导是布局系统性问题，不是点修** | ⑫ ㉓ ㉖ ㉗ ㉞(前半) ㉚ ⑱ | ㉗ 已经是用户给的整面规格；⑫㉖㉓㉞㉚ 都是这张面（或建会话向导）上的具体条款，逐点修会返工，按规格一次重做 |
| **Y5 分享的完整产品形态 = 气泡+unfurl+挂载，且业务不该住 controller** | ㉙ ㉝ 债③ 规则8 | 分享/接收是一条链：签 token（现成）→ 气泡/unfurl 呈现 → 点击挂载（现全在 web controller 里做业务，P13 违反）→ 只读者申请编辑（规则8，未实现）。接收业务先搬进 kanban plugin（债③），气泡/申请都长在它上面 |
| **Y6 install 状态投影失真** | ⑩ ㉑ | `unfilled_agent_role_slots` 写侧只在 install 时记（session_creator.ex:234），读侧（conversation_data.ex:58）原样透传不对照当前成员表——补员后横幅仍报未装载；建会话向导则根本不消费 skipped |
| **Y7 dev 环境债（非产品）** | ⑪ ⑬ ⑮ | 三条独立小修，共同点只是"dev 下才暴露" |
| **Y8 独立管理面缺失** | ⑭ ㉛ ⑲ | 三个"机制在、UI 面没有"：邀请码（mix task 在）、装 sw/存模板（install/retract/save_session_template API 全在）、删板（Manage cap + retire 语义在） |

---

## 二、逐条修法表

### Y1 实时推送族：⑰ ㉒ ㉘ ㉞

**X/Y 拷问**：X 是四个"别人的界面不刷新"现象；Y 是**一个**缺口——状态变更（成员、挂载、看板 slice）只有操作方本地 push_event，没有 server 侧向所有订阅者的广播。修根 = 补发布侧，**不是**给每个现象各加一个轮询。
注意"已保存"（㉞）是这个 Y 的可视化谎言：`last_dispatch_status=="ok"` 常驻渲染成"✓已保存"（Kanban.tsx:661），页面又不实时同步，读起来像假话。

**修法**（订阅侧全部现成，只补发布侧 + 处理侧）：

1. **⑰ 成员/会话变动 → per-user 推送**
   - 通道现成：`subscribe_global_inbound` 已订 `Ezagent.Notifications.topic(caller_uri)`（world_live.ex:836）且 `handle_info({:notification, ...})` 已有（world_live.ex:203）。
   - 改动：membership 写路径（session join/add、workspace 加成员）成功后 `Ezagent.Notifications` 发一条到**被加者** topic（payload 带 `{:membership_changed, session_uri}`）；WorldLive 收到后重拉 session 列表推 `world:state`。
   - 锚：`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:781 handle_join` 的成功分支（用 `:notify` effect，9 effects 现成，不引 PubSub 直呼）。
   - 大小：**M**。归属：domain_session（notify effect）+ world（handle_info 分支）。
2. **㉘/㉒-① 看板变更 → 同会话成员广播**
   - board 是 workspace 级 agent，不在 session events topic 上。修法：kanban behavior 的写 action（add/rename/move/remove/claim/unclaim/set_status/drop/attach…）返回 effects 里补一个 `{:emit, ...}`（板自己的 events topic，emit 是 sanctioned effect，不违 P14）；WorldLive 在看板数据载入时订阅该 board 的 events topic（照 `maybe_subscribe_pty` 先例，world_live.ex:85），收到后按 `read_ctx` 重拉 `KanbanData.board_state` 推 `world:state`。
   - 建板刷新（㉒-①）：`create_kanban` 本人路已有 push_event（kanban_actions.ex:397），"别人看到新板"由 board 列表变更走同一订阅（或 session events topic 上的 mount 事件）。
   - 大小：**M**。归属：kanban plugin（emit effect）+ world（订阅+handle_info）。
3. **㉒-② tab 态进 URL（view 深链）**：`/sessions?session=...&view=kanban_board`，`Routes.route_for` + React 侧读写。刷新不再掉回对话 tab。大小：**S-M**。归属：world。
4. **㉞**：分两步——本批先把常驻"✓已保存"（Kanban.tsx:661）摘掉换 per-action 轻提示（失败 toast 已有）；推送落地后如需"同步状态"再加真实指示。大小：**S**。

**归属与顺序**：world 实时面 + kanban plugin emit。是批 B（多条后续项的体验依赖它）。
**不该做**：不要引入独立轮询（@refresh_ms 扩大化）；不要 `PubSub.broadcast` 到 inbound topic（P14 事故 2.1）。

### Y2 join 补发：⑤TODO ⑧TODO（+㉜ step1）

**X/Y 拷问**：X = 后加入成员看不到看板 tab、没有板钥匙。Y = **「新成员进 session 时拿到该 session 已挂资源的钥匙」没有机制**——install 点（`grant_installer_view_caps`，installation.ex:348-385）和 mount reconcile（mount.ex:156，只按已记录 grantee 重发）都覆盖不到 join。collab 模型 C1 已定"编辑成员都持钥匙"，所以这不是产品未定，是机制缺口。

**修法**（过渡实现，永久机制归 Allen #1394）：
- 在 `handle_join`（session.ex:781）成功路径加一个补发 hook：
  1. **view caps**：把 `grant_installer_view_caps/2` 泛化为 `grant_member_view_caps/2`（同一个 `view_render_caps` 内核，installation.ex:387，rule tag 换 `{:rule, :socialware_member_views, member}` 同族），对新成员补发所有已装 definition 的 declared view render caps。
  2. **board 钥匙**：读 `MountRow.list_for_session/1`，对每条 `access: :operate` 的挂载行，给新成员 `Mount.mount/6` 同款钥匙（新增 grantee 行，幂等 upsert）。`access: :read` 行不扩散（只读挂载不自动升级）。
- 幂等/重入：mount upsert + Cap.issue absorb 都幂等，join 重放安全。
- 大小：**M**。归属：domain_session（通用机制，零 kanban 字面——照 ⑤ 修法先例）。
- **留 Allen 的点**（实施可先行、标注待确认）：① rule 名进 Decision Log（与 ⑥ 的 `:socialware_runtime_provision` 一起）；② "join 即发 operate 钥匙"的授权面（编辑 session 成员=全钥匙，是 collab 模型 C1 的直译，但这是 ambient-rule 家族的又一员，#154 review surface）；③ 永久形态并入 #1394 Entity 双向-caps/mount 线。

**不该做**：不要在 world/前端侧"补拉"绕过（那是把授权洞藏起来）。

### Y3 职责倒挂：⑳（BoardProvision 降级）＋ ㉜ step2（tab=plugin 级）

**⑳ X/Y**：X = 没有 assistant（cc 凭证缺）时建板整体失败。Y = create_board 把 **sw 增强**（assistant 钥匙）做成了**plugin 基线**（建板）的硬前置——`resolve_assistant` 在 with 链最前（board_provision.ex:68），解析不出直接 fail-closed。
**修法**：调整 `create_board/5` 主链 = 建宿主（`Mount.provision` 改为直接以 creator 为 grantee，或 provision 后先发 creator 钥匙）+ 发建板人钥匙；assistant 解析成功才附加 `Mount.mount` 给 assistant，失败则 `assistant_uri: nil, minted: []` 正常返回（留待 Y2 补发/reconcile 补）。同步把 `resolve_assistant` 从 with 链前部移到可选段。
大小：**S-M**。归属：domain_session（BoardProvision glue，行为反转无新机制）。测试改 `board_provision_grant_test.exs` 加"无 assistant 也建成"用例。

**㉜ X/Y**：X = 没装 kanban sw 的会话看不到看板 tab。Y = **tab 的存在应表示"系统装了 kanban plugin"**（plugin 级），被门控的应是板内容/钥匙，不是 tab 显隐。
**与 ⑤/main view-cap 线的相抵核对**（现读）：tab 显隐由两道门串联——
1. `BoardView.applies_to?/1`（board_view.ex:51-59）：按 `installed_definitions` 含 KanbanRender 判——**sw 级门，kanban 自己的，改它不撞 Allen**；
2. `SessionViewRegistry.applicable_views/2`（session_view_registry.ex:92-102）→ `SessionView.authorize_view/3` 查 `{Session, :kanban_render}` cap——**T2-2b caller-aware cap gate，平台契约**，"没 cap 的 caller 连 tab 都不见"是 main 设计（#1362 composition/view-cap 线）。

所以 ㉜ 拆两步：
- **step1（本计划内，批 C）**：Y2 join 补发落地后，"装了 sw 的会话内**所有成员**见 tab"达成（⑤ 只修了 installer）——不动平台门。
- **step2（待 Allen）**：真"所有会话恒显 tab"需要二选一：(a) `applies_to?` 恒 true + 给全体登录成员按 plugin 基线发 `kanban_render` cap（cap gate 语义不动，发钥匙面变宽）；(b) 允许 view 声明"ungated/plugin-level"跳过 authorize_view（改 T2-2b 契约）。两个都是 view-cap 门控模型决策，**与 Allen 的 view-cap/composition 线对齐后再做，本计划不实施**。过渡缓解：分享点击挂载时顺发 render cap 给点击者（见 Y5-㉝），保证"分享链接在任何会话点开有意义"（用户点3）不被 step2 阻塞。

### Y4 面板/向导布局批：⑫ ㉓ ㉖ ㉗ ㉚ ⑱（+㉞ 前半）

**X/Y 拷问**：X 是七八个 UI 点；Y 是**看板面板没按规格设计过**（㉗ 就是用户给的规格书）+ 向导/主题两个独立小 X。按 ㉗ 规格一次重做面板，⑫⑱㉚ 是同批独立小修——合并成一个前端 PR 而不是八个点补丁。

| 条 | 修法 | 锚 | 大小 |
|---|---|---|---|
| ㉓ 本图配置移除 | 删"本图配置"块（含 GitHub 仓库/Miro 板名字段+保存按钮）；Miro 板名只在 sync_miro 弹窗填（已实现 Kanban.tsx:212）；repo 缺失时 register_pr 就地问 | Kanban.tsx:162-164, 265-280；`kanban.set_board_config` 通道保留（behavior 不动，去的是常驻 UI） | S |
| ㉗ 面板布局规格 | 前两排信息+「加子」「认领」保持；其余一条信息一排；产物区改「添加」+下拉（链接/内容/画图/附件）+ 按钮；**去 SHA 选项**（attach_code_file 入口删，动作保留纯数据）；**补附件上传**（`kanban.attach_upload` 通道已在，kanban_actions.ex:125-131，平台 uploads 现成）；**每个产物加删除钮**（`detach_artifact` 动作已有 kanban.ex:536，缺入口）；「内容」编辑弹大框 md 编辑器（照 ExcalidrawModal.tsx 交互形态；textarea 编辑器雏形已有 Kanban.tsx:350） | Kanban.tsx:519-596 产物区重写 | M |
| ㉖ 名称就地编辑+框宽 | 面板顶部标题改就地编辑输入框（替代底部「改名」`window.prompt`，Kanban.tsx:596）；KanbanCanvas 节点框自适应文本宽或悬停显全名 | Kanban.tsx:596；KanbanCanvas.tsx | S-M |
| ⑫ 向导创建按钮 | 向导容器加 max-height+overflow 或按钮固定底部 | SessionsTable.tsx:180-255 表单区 | S |
| ㉚ 剪贴板 | `navigator.clipboard` 失败回退（select+execCommand）+ 真实成败反馈；删"已自动复制"误导文案 | Kanban.tsx:63 附近分享块 | S |
| ⑱ 深色主题 | 排查硬编码浅色：Conversation.tsx:863 `bg-[linear-gradient(#ffffff...)]`、:684 `bg-[#fff2a6]`、:1724 `bg-white`、Kanban/KanbanCanvas 同类——换 token（`bg-background`/dark variant） | root data-theme 机制现成（root.html.heex:21） | S-M |
| ㉞ 前半 | 摘常驻"✓已保存" | Kanban.tsx:661 | S |

**归属**：全部 world 前端（+零星 world actions 入口）。**不该做**：不要顺手改 behavior 动作签名（attach_code_file/set_board_config 动作保留，只动 UI 入口——动作收敛另议）。

### ㉕ drop 重定义（跟踪标红，非删除）

**X/Y 拷问**：X = drop 和删除入口重复。Y（用户已细化）= **drop 的产品语义本来就不是删除**——北极星指标不达标时的"跟踪标记"。修根 = behavior 语义改写，不是 UI 藏按钮。
**修法**：`handle_drop_subtree`（kanban.ex:358-397）从"Map.drop 砍子树"改为**非破坏性标记**：①节点+子树打 `dropped: true`（或 `dropped_at/by/reason` 字段）；②不动 nodes；③ `:drops` 历史保留、entry 加 `reason`（现 entry 结构 kanban.ex:380-384 补一键）；④授权改**节点认领人**（`node.owner == caller` or `board_admin?`），去掉整树校验（整树校验留给 `remove_node` 的规则5）。`handle_get_tree`（:559）投影带 dropped 标；前端红框渲染（KanbanCanvas）。开放点（un-drop、红框内他人认领节点显示）在 PR 里给默认（可 un-drop=认领人；红框全子树同色）并标注待确认。
大小：**M**（behavior+投影+前端）。归属：kanban plugin + world 前端。**注意**：改语义后 `drop_authorized?`（:368）与 remove 的校验分道——补测试。

### Y5 分享闭环：债③ ㉙ ㉝ 规则8

**X/Y 拷问**：X = 四个散点（controller 厚、缺气泡选项、链接不 unfurl、申请编辑没有）。Y = **分享/接收是一条产品链，接收业务现在住在 transport 层**（kanban_share_controller.ex:51-66 做了 verify+落点解析+mount，P13 违反），气泡/unfurl/申请编辑都要长在"接收动作"上——先把接收业务搬到 plugin（债③，不动平台就能搬，debt note 已判），其余三条才有正确的挂点。

1. **债③ controller→薄 dispatch**：kanban plugin 新增 `receive_shared_board(token_payload, clicker, target_session \| nil)` 模块（plugin 向下调 domain 的 `Mount.mount` 合法；①的分层问题是 domain 里有 kanban 字面，方向相反）：落点解析（target_session 为 nil 时沿用"第一个带 assistant 的 session"口径，controller.ex:97-125 搬过来）+ 只读 mount + **顺发 `kanban_render` render cap 给点击者**（㉜ 过渡：点开的人能看到 tab；照 `view_render_caps` 内核）。controller 瘦成 verify token（Phoenix.Token 是 web 层的，留下）+ 调 plugin + redirect。大小：**M**。
2. **㉙ 分享到会话（气泡）**：分享对话框加"分享到会话"选项——签同一个 token，`session.send` 一条带板引用的结构化消息（`JsonRenderBubble.tsx` 气泡通道现成）；"逻辑上都是一个链接，按点击者过滤"= 点击走同一 receive 链，权限由点击者身份决定（本会话编辑成员本就持 operate 钥匙，其余人只读 mount）。大小：**M**。归属：world 前端+conversation 消息渲染。
3. **㉝ 链接 unfurl+点击挂载**：Conversation 消息渲染识别 `/socialware/kanban/claim?token=` 链接 → 渲成 ㉙ 同款气泡；点击气泡带**当前 session_uri** 走 world dispatch `kanban.claim_shared`（调 receive_shared_board，target=当前会话——修 controller"挑第一个 session"的落点错位）。至少先把纯文本链接变可点。大小：**M**。与 ㉙ 同批同气泡形态。
4. **规则8 申请编辑**：未实现。落法：①只读用户看板面出「申请编辑」键 → dispatch 板的新 action `request_edit`（记 pending 申请进 `:kanban` slice）；②向"编辑 session"chat 发批准气泡（C4：批准人=版主 data_owner，气泡发到 mount 表里 access=operate 的 session）；③版主批准 → `Mount.mount` 升级该用户为 operate。大小：**L**（behavior 新 action+气泡+批准链）。依赖 ㉙ 气泡形态 + Y1 推送（批准气泡实时到）。可拆两步：先申请记录+版主看板面内批准（无气泡），气泡后补。

**不该做**：不要在 controller 里继续加逻辑（unfurl 点击直接打 HTTP claim 再 302 回来那种绕路）；跨 ws 分享已被 #1435 收紧（board_provision.ex:292-300 `same_workspace`），⑯ 业务边界不要再放开。

### Y6 install 投影失真：⑩ ㉑

**X/Y 拷问**：X = 横幅不刷新/向导无提示。Y = **skip 记录是 install 时刻的快照，读侧不对照现状**。写侧其实已设计成"每次 install 重写清 stale"（session_creator.ex:232 注释），但后台补员不走 install，记录就永远失真。修读侧比改写侧稳（不引入新写点）。
**修法**：
- ㉑：读侧过滤——`conversation_data.ex:58`（和 conversation_actions.ex:965 同款）读 `unfilled_agent_role_slots` 后对照当前成员表（`:session` slice members 的 role_name），role 已有成员的行剔除。**S**。
- ⑩：建会话链路把 `%{skipped: ...}`（session_creator.ex:329-343 已返回）带回向导 UI 显示一次性提示（"kanban-assistant 未装载：缺 Claude 凭证"）。**S-M**。归属：world 数据投影/向导。

### Y7 dev 环境债：⑪ ⑬ ⑮

- **⑮ 确认信域名**：dev.exs 覆盖 `config :ezagent_plugin_email, :verification_base_url, "http://localhost:10042"`（现 config.exs:148 写死生产域名；runtime.exs:60 只在 prod runtime 覆盖）。**S（一行）**。
- **⑬ WS 退 longpoll/vite 骨架屏**：先查 WS 被拒根因（大概率 `check_origin` 在经 `http://<IP>` 访问 dev 时拒握手→退 longpoll；endpoint.ex:31）。修 dev.exs `check_origin: false`（或列 IP）；vite 冷启骨架屏是资产首载体验，确认 `world_module_url`（world_live.ex:549）dev 指向 vite dev server 的时序。**S 调查修**。
- **⑪ dev 发布车道**：boot scan 是刻意 prod-only（config.exs:29，#1224 设计）；mix import 撞运行 server 的 _build 是因为它另起 VM。**干净修 = 走现成分布式 RPC CLI**（`mix ezagent` shell，ezagent_cli），把 `socialware.import` 暴露成 RPC 命令在运行节点内执行（`publish_or_upgrade` 幂等）。**M**。⚠️ "dev 也开 boot scan"是设计口径变更，**先问 Allen（#1224）再动 config**，RPC 路不动口径可先做。

### Y8 管理面缺失：⑭ ㉛ ⑲

- **⑭ 邀请码管理面**：机制在（`mix ezagent.invite`，apps/ezagent_domain_identity/lib/mix/tasks/ezagent.invite.ex；registration_controller.ex:8 消费）。修法：identity 侧把铸码/列码收口成可 dispatch 的 API（或复用 task 内核成域函数），world 管理面加"邀请码"卡（铸/列/失效）。**M**。归属：world + identity 薄 API。按 ⑭ 判定，**不要**给 `workspace.add_member` 补 UI（邀请码模型下成员"出生"进 ws，那接口的存在性待审）。
- **㉛ 装 sw 面+存模板**：机制全在——install（`Installation.install_template_installs`）、卸载（`retract_session_installs` #1245）、world 侧 `socialware_install.ex`（210 行）和 `save_session_template`（workspace_plugin_actions.ex）。缺的是会话设置里的面：已装列表（`installed_definitions`，installation.ex:470）+ 多选装/卸 + "保存为 session template"按钮 + 模板发布。**M**。归属：world 前端+现成 actions 接线。
- **⑲ 删板 UI**：机制在（建板人持 Manage cap；#1411 后走 `Ezagent.Domain.Agent` retire 语义）。修法：world 加 `kanban.delete_board` dispatch → 校验 caller 持 Manage → retire board agent + `Mount` 挂载行清理（unmount 逐行，mount.ex:86 现成）+ 前端导图列表删钮（确认框）。孤儿板清理顺带解决（板主/admin 可删）。**M**。归属：world actions + kanban 面。⚠️ retire 要走 `Domain.Agent` 门面（#1411），不要直调 terminate。

---

## 三、分批实施计划（一批 = 一个 PR）

依赖顺序（→ = 阻塞）：**B → C → D**；A、E、F 独立可并行；G 待 Allen 不排期。

| 批 | 名 | 内容 | 大小 | 依赖 |
|---|---|---|---|---|
| **A** | 看板面 UX+drop 语义 | Y4 全部（⑫㉓㉖㉗㉚⑱㉞前半）+ ㉕ drop 标红（behavior 小改+前端红框）+ ⑮ 一行搭车 | M-L（但全低风险） | 无，**先行** |
| **B** | 实时推送环 | ⑰（membership notify）+ ㉘㉒-①（kanban emit+订阅）+ ㉒-②（view 深链）+ ㉞ 后半 | M | 无 |
| **C** | join 补发+职责反转 | Y2（join hook：member view caps + board 钥匙补发，⑤⑧TODO 收口，㉜step1 顺带达成）+ ⑳（assistant 降级为增强）+ Y6（⑩㉑ 投影修） | M | 无（但 ㉑ 横幅体验依赖 B 才实时） |
| **D** | 分享闭环 | 债③（controller→plugin receive 动作+顺发 render cap）→ ㉙ 气泡 → ㉝ unfurl+点击挂载 → 规则8 申请编辑（可再拆一个 PR） | L | B（批准气泡实时）、C（钥匙机制稳定） |
| **E** | 管理面 | ㉛ 装 sw 面+存模板 + ⑭ 邀请码面 + ⑲ 删板 UI | M-L | 无（⑲ 与 D 无耦合） |
| **F** | dev 体验 | ⑬ WS/vite 调查修 + ⑪ RPC import 路（口径不动） | S-M | 无，随时插空 |
| **G** | 待 Allen（不实施，列决策单） | ㉜step2（tab=plugin 级恒显的 view-cap 门控模型，T2-2b 契约）；⑥/C 批 rule 名进 Decision Log（`:socialware_runtime_provision`/`:socialware_member_views`）+ transient ctx-cap 用法确认；join 补发永久机制并 #1394；⑪ dev boot-scan 口径（#1224）；gap3 cc-plugin 三缺口（prompt/skill/mcp 桥，Allen/gaga 线）；债①②（BoardProvision 出 domain / kanban view 出 world 的分层永久修） | — | Allen |

**最大风险点**：
1. **批 C 的授权面**——"join 即发 operate 钥匙 + member view caps"是两条新 ambient rule（#154 review surface），实施可先行但 rule 名和边界必须进 Decision Log 等 Allen 追认；做错方向=又一轮 cap 返工。
2. **㉜ 两步不要抢跑**——step2 动 T2-2b caller-aware view gate 是平台契约，本计划只做 step1+分享点击顺发 render cap 的过渡；谁在批 D 里"顺手"把 `applies_to?` 改恒 true 就撞了 Allen 的 view-cap/composition 线。
3. **批 B 的 emit 通路**——kanban 写 action 加 `:emit` 时注意别把广播做成 inbound dispatch（P14）；订阅清理照 PTY 订阅泄漏的教训（world_live.ex:149-155 注释）做好退订/过滤。
