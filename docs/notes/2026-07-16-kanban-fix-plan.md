# kanban 修法计划 v3 —— 归属重切版（2026-07-16 晚）

**术语纠正（沿 v2）**：本版遵循用户口径 —— **Y = 看到的现象，X = 根因**。v1 把标签用反了（X=现象、Y=真问题），方向也因此偏成"从现象归并"；v2 起从根因（X）出发定修法。所有锚点现读代码核实（HEAD `e015e630d`，代码同 `743ed6178`，其上只有 docs commit）。

**归属重切（2026-07-16 晚，用户定，v2 的切法被否）**：v2 按"谁改哪个文件"切归属，把 kanban 前端整包给了 zyli——错。新原则：

- **我们（PR #1374 线）**：kanban 是**自包含 plugin**，声明式插入 world——**所有围绕 kanban 自包含的东西都我们修，不交给任何人**，含 kanban 前端（Kanban.tsx / KanbanCanvas / kanban 面板 / 看板 tab 刷新 / 分享对话框 / drop 标红 / 删板 UI）。kanban 的界面不归 world 负责人管。
- **Allen**：他在做**权限**（#1438 cap-signing per-Kind authority v7、#1412/#1409 capbac follow-ups）——**系统层面的权限/契约/rule 决策**给他，不实施。
- **gaga**：他在做 **agent runtime**（#1434 skill 加载、#1423 Git provider/provisioning）——只给他 agent runtime 相关（#1323 headless-MCP、凭证供给、cc-headless）。
- **zyli**：world（ezagent 界面）负责人——**除 kanban 以外的前端** + 推送环的 world 订阅/分发基建。

X/Y 分析不变；下文各「归属」行与 §三、§四 已按新原则重写。

输入 = `2026-07-15-kanban-layering-debt.md` 全部未修项（⑤-㉞ + 债③ + 规则8）+ `2026-07-15-kanban-collab-model.md`（模型定稿）。

---

## 一、六个根因（X），每个 X 一组

### X1 —— world 是「拉模型 + 操作者自刷」，设计上没有 server→同会话成员的推送环

- **Y（现象们）**：⑰ 被加进会话不刷新、㉒-① 建板后列表不刷新、㉘ 他人取消认领画布不刷新、㉞ "✓已保存"读起来像假话。
- **X（一句话）**：这不是四个前端 bug —— 状态变更（成员/挂载/看板 slice）只有操作方本地 `push_event`，**发布侧从来没人往任何 topic 广播**，是架构缺口。
- **证据**：订阅侧其实现成 —— WorldLive 已订 per-user `Ezagent.Notifications.topic(caller_uri)`（world_live.ex:836）且有 `handle_info({:notification, ...})`（:203）、打开会话时订 per-session topic（:106 `ensure_session_subscribed`）、PTY 有订阅先例（:888 `maybe_subscribe_pty`）。发布侧：`handle_join` 成功路径（session.ex:781 起）零 notify；kanban 写 action（add/claim/unclaim/move…）返回 effects 零 `:emit`；board 是 workspace 级 agent 根本不在 session topic 上。
- **从 X 修**：补一个「变更→广播」环，只用 sanctioned effects（不新造机制）：
  1. membership 写路径成功后 `:notify` effect 到**被加者** per-user topic（payload `{:membership_changed, session_uri}`）——锚：session.ex:781 成功分支 + workspace 加成员路。
  2. kanban 写 action 补 `{:emit, ...}` 到 board 自己的 events topic；WorldLive 载入看板数据时照 PTY 先例订阅该 topic，收到后按 `read_ctx` 重拉 `KanbanData.board_state` 推 `world:state`。
  3. 建板/挂载变更同理（㉒-① 由 board 列表变更覆盖）。
  4. ㉞ 是这个 X 的可视化谎言：常驻 "✓已保存"（Kanban.tsx:661，`last_dispatch_status=="ok"` 常驻渲染）先摘掉换 per-action 轻提示；推送落地后如需再加真实同步指示。
  5. ㉒-② tab 态进 URL（view 深链 `/sessions?session=...&view=kanban_board`）——严格说不是推送环，但同批前端顺修。
- **只修 Y 的诱惑**：给四个现象各加一个轮询 / 扩大 `@refresh_ms` / 操作完本地多推几次 —— 每多一个面就再赔一次，而且轮询治不了"别人的界面"。**红线**：不许 `PubSub.broadcast` 到 inbound topic（P14，事故 2.1）。
- **归属（重切）**：发布侧（domain_session membership `:notify` + kanban 写 action `:emit`，都在我们业务代码里）= **我**；world **订阅/分发基建**（WorldLive per-user/per-session 订阅、退订、事件转发到前端的通用通道）= **zyli**；**kanban 面的事件消费**（订 board events topic + 收到后按 `read_ctx` 重拉 `board_state` 推 `world:state`：㉒-① 建板列表刷新、㉘ 画布刷新、㉞ 摘假"已保存"）= **我**（kanban 前端归 kanban）；⑰ 会话列表/成员面板刷新 + ㉒-② tab 态深链 = **zyli**（world 会话面状态）。两侧接口 = payload 约定（见 zyli handoff §接口约定）。

### X2 —— 「人进入协作场景时的授权供给」没有产品化机制

- **Y（现象们）**：⑤⑧ 的 join 缺口（后加入成员没 view cap / 没板钥匙）、⑥（installer 建板无 create_agent 授权点）、⑭（邀请码只有 mix task 没产品面）、㉜（后加入成员看不到看板 tab）。
- **X（一句话）**：install 是**一次性发钥匙点**，而成员是**动态进出**的（邀请码进 workspace、join 进 session、板是后建的）——每个"进入时刻"的钥匙供给全靠不存在的补发；⑭ 和 ㉜ 都是同一个 X 在不同入口的症状。
- **证据**：`grant_installer_view_caps/2` 只挂在 install 点、只覆盖 installer（installation.ex:349-385）；`Mount.reconcile_session_mounts/1` 只按挂载行重发**已记录 grantee**（mount.ex:156-183），发不到新成员；`handle_join`（session.ex:781）成功路径零补发 hook；workspace 入口只有 `mix ezagent.invite`（in-VM task）→ registration_controller.ex:8 消费，零管理 UI；⑥ 全链路无普通用户 `create_agent` 授权点（layering-debt ⑥ 调查结论）。
- **从 X 修**：把「**进入即供给**」立成机制，三个入口各补一个供给点：
  1. **session 入口（join hook）**：`handle_join` 成功路径补发 —— (a) `grant_installer_view_caps` 泛化为 `grant_member_view_caps`（同一 `view_render_caps` 内核 installation.ex:387，rule tag `{:rule, :socialware_member_views, member}` 同族）；(b) 读 `MountRow.list_for_session/1`，对 `access: :operate` 行给新成员发同款钥匙（幂等 upsert；`:read` 行不扩散）。
  2. **workspace 入口（邀请码面）**：铸码/列码/失效收口成可 dispatch 的 identity 薄 API + world 管理卡。**不要**给 `workspace.add_member` 补 UI（⑭ 判定：邀请码模型下成员"出生"进 ws，该接口存在性待审）。
  3. **"建"动作入口（⑥）**：`create_agent` 授权三选项（a/b/c，见 layering-debt ⑥）是平台级授权决策，现行 `{:rule, :socialware_runtime_provision, creator}` transient 是过渡。
  - ㉜ 拆两步不变：step1 随 join 补发达成（成员见 tab）；step2（tab=plugin 级恒显）动 T2-2b caller-aware view gate（session_view_registry.ex:92-102 → `authorize_view/3`），平台契约。
- **决策先行**：join 补发 = ambient rule 家族新成员（#154 review surface），rule 名/授权面（"编辑成员=全钥匙"是 collab C1 直译）/永久形态（#1394 Entity 双向-caps）**归 Allen 拍板，拍板后我实施**（domain_session 通用机制，零 kanban 字面，照 ⑤ 修法先例）。
- **只修 Y 的诱惑**：前端"补拉"绕过 cap（把授权洞藏起来）、后台手工铸 cap 让 demo 过、每个现象各加一个 grant 点（第 N 个 grant 点 = 第 N 个不同步的真相源，正是 X3 的病）。

### X3 —— 「声明的角色」与「实际成员」两个真相源不同步

- **Y（现象们）**：⑩ 凭证缺失 install 静默跳过角色向导无提示、㉑ 后台补员后横幅仍报"未装载"、⑳ 没 assistant 时建板整体失败。
- **X（一句话）**：install 的 role 物化是 **best-effort**（skip 记录进持久快照，session_creator.ex:321-343 + :234 `record_unfilled_role_slots`），但下游当它是**强保证**：建板把 assistant 解析放 with 链最前 fail-closed（board_provision.ex:68 `resolve_assistant`），横幅原样透传 install 时刻快照不对照当前成员表（conversation_data.ex:58）。
- **从 X 修**（三面同治，认清"声明≠现状"）：
  1. **下游降级（⑳）**：`create_board/5` 主链 = 建宿主 + 发建板人钥匙（plugin 基线）；assistant 解析成功才附加 `Mount.mount`（sw 增强），失败 `assistant_uri: nil, minted: []` 正常返回，留待 join 补发/reconcile。`resolve_assistant` 移出 with 链前部。测试补"无 assistant 也建成"。
  2. **读侧对照现状（㉑⑩）**：投影时把 role 已有成员的行剔除（对照 `:session` slice members 的 role_name）；建会话链路把已返回的 `%{skipped: ...}`（session_creator.ex:329-343）带回向导显示一次性提示。
  3. **上游供给（⑩ 根因侧）**：cc-headless 无凭证源 → install 静默 skip，凭证供给面 + skip 可观测归 **gaga**（provisioning 域）。
- **只修 Y 的诱惑**：只把横幅改成会过期的 toast（⑩㉑ 消失但 ⑳ 还炸）；或给 skip 加自动重试把 best-effort 伪装成强保证（凭证不存在重试一万次也不存在）。
- **归属**：1 = **我（本 PR）**；2 = **zyli**（world 投影/向导——`unfilled_agent_role_slots` 是通用 role-slot 投影 + 建会话向导，属 world 会话面，非 kanban 界面）；3 = **gaga handoff**（上游 = `Ezagent.Agent.CredentialPrecondition` 判 NONE 即 skip 的凭证供给/绑定面）。

### X4 —— 看板面从 demo 长出来，没有经过设计规格

- **Y（现象们）**：⑫ 向导按钮点不到、㉓ 本图配置块、㉖ 改名藏 prompt/节点框截断、㉗（= 用户给的整面规格）、㉚ 剪贴板静默失败、㉞ 前半"✓已保存"、⑱ 深色主题白屏刺眼。
- **X（一句话）**：这张面板没被设计过，是 demo 顺手长的；㉗ 就是规格书 —— **修 = 按规格一次重做，不是七个点补丁**。
- **从 X 修**：一个前端 PR 按 ㉗ 规格重做节点面板（Kanban.tsx:519-596 产物区：「添加」+下拉 链接/内容/画图/附件、去 SHA 入口、补附件上传 `kanban.attach_upload` 通道已在、每产物删除钮 `detach_artifact` 动作已有 kanban.ex:536、「内容」弹大框 md 编辑器照 ExcalidrawModal 形态）+ ㉓ 移除本图配置块（:162-164, :265-280；Miro 板名只在 sync_miro 弹窗填 :212）+ ㉖ 标题就地编辑（替代 :596 `window.prompt`）/画布节点框自适应 + ⑫ 向导 max-height/按钮固定底（SessionsTable.tsx:180-255）+ ㉚ clipboard 回退+真实反馈（:63 附近）+ ⑱ 硬编码浅色换 token（Conversation.tsx:863/:684/:1724 及 Kanban/KanbanCanvas 同类；root data-theme 机制现成 root.html.heex:21）+ ㉞ 摘 :661。
- **只修 Y 的诱惑**：逐点打补丁 —— 每个补丁都会在按规格重做时返工；或"顺手"改 behavior 动作签名（attach_code_file/set_board_config **动作保留**，只动 UI 入口）。
- **归属（重切）**：kanban 面板整包（㉗ 规格重做 + ㉓㉖㉚㉞ + Kanban/KanbanCanvas 里的硬编码浅色 token 化，随重做吸收）= **我（本 PR）**——kanban 自包含，它的界面自己修；⑫（建会话向导，SessionsTable）+ ⑱ 的 **Conversation 层**硬编码浅色（Conversation.tsx:863/:684/:1724）= **zyli**（world 会话面）。

### X5 —— dev 环境与 prod 车道分叉

- **Y（现象们）**：⑪ dev 无 socialware 发布车道、⑬ WS 退 longpoll/vite 冷启骨架屏、⑮ 确认信链接是生产域名。
- **X（一句话）**：三条都是「prod 车道是唯一被设计过的车道」的症状 —— 发布 boot scan prod-only（config.exs:33 `socialware_manifest_boot_scan: config_env() in [:prod]`，#1224 刻意设计）、域名 prod 硬编码（config.exs:148 `"https://app.ezagent.chat"`，runtime.exs:60 只在 prod runtime 覆盖）、dev 资产/WS 时序没人管（endpoint check_origin / vite）。
- **从 X 修**：给 dev 补一条被设计的车道，而不是逐个 workaround：
  1. ⑮ dev.exs 一行 `config :ezagent_plugin_email, :verification_base_url, "http://localhost:10042"`（**我，本 PR 搭车**）。
  2. ⑪ 干净修 = 走现成分布式 RPC CLI（`mix ezagent` shell），`socialware.import` 暴露成 RPC 命令在运行节点内执行（`publish_or_upgrade` 幂等）——口径不动可先做（**我，独立小 PR**）；"dev 也开 boot scan"是 #1224 口径变更，**问 Allen**。
  3. ⑬ 查 `check_origin`（endpoint.ex:31，经 `http://<IP>` 访问被拒握手→退 longpoll 的最可能因）+ vite dev server 时序（world_live.ex:549 `world_module_url`）——**zyli**（dev 前端体验）。
- **只修 Y 的诱惑**：手动 workaround（改 hosts、手工在 iex 里发布）——每个新 dev 环境/新同事重赔一次。

### X6 —— 分享作为产品动作没有闭环

- **Y（现象们）**：㉙ 缺"分享到会话"气泡、㉝ 链接粘进 chat 不 unfurl 不可点、规则8 申请编辑不存在、债③ 接收业务住在 web controller。
- **X（一句话）**：分享只做了半件（生成只读链接）；接收/呈现/升级编辑整条链没有产品归宿 —— controller 里的业务（kanban_share_controller.ex:51-66：verify + `resolve_target_session` 挑"第一个带 assistant 的 session" + `Mount.mount`，P13 违反）正是**闭环缺 plugin 归宿**的症状，不是一个独立整改项。
- **从 X 修**：先给闭环一个归宿，其余长在它上面：
  1. **债③（归宿）**：kanban plugin 新 `receive_shared_board(token_payload, clicker, target_session | nil)`（plugin 向下调 domain `Mount.mount` 合法；与债① 方向相反不冲突）：落点解析（nil 时沿用现口径）+ 只读 mount + **顺发 `kanban_render` render cap 给点击者**（㉜ 过渡：点开的人见 tab）。controller 瘦成 verify token（Phoenix.Token 属 web 层，留下）+ 调 plugin + redirect。
  2. **㉙ 分享到会话**：分享框加选项 —— 签同一 token，`session.send` 一条带板引用的结构化消息（气泡通道 JsonRenderBubble 现成）；"逻辑上都是一个链接，按点击者过滤"= 点击走同一 receive 链。
  3. **㉝ unfurl**：Conversation 渲染识别 `/socialware/kanban/receive?token=`（router.ex:261）→ 渲成 ㉙ 同款气泡；点击带**当前 session_uri** 走 `kanban.claim_shared`（修 controller 落点错位）。
  4. **规则8 申请编辑**：板新 action `request_edit`（pending 记进 `:kanban` slice）→ 批准气泡发到 mount 表 access=operate 的"编辑 session" chat（C4：批准人=版主 data_owner）→ 批准即 `Mount.mount` 升级 operate。可拆两步（先板面内批准，气泡后补）。依赖 X1 推送 + ㉙ 气泡形态。
  5. **⑯ ws 口径**：`forward_board` 有 `same_workspace` 硬守卫（board_provision.ex:267,:292）而链接分享路无 ws 检查——两路口径不一，**统一方向归 Allen**（用户倾向：系统支撑就放开）。
- **只修 Y 的诱惑**：在 controller 里继续加 unfurl/气泡逻辑（P13 债滚大，将来搬家做两遍）；或先做前端 unfurl 再搬业务（同样做两遍）。
- **归属（重切）**：plugin 侧动作（债③ receive、规则8 `request_edit`、㉙ 的 dispatch）+ **kanban 前端半边**（㉙ 分享对话框两选项 UI、㉝ 气泡**点击后的挂载动作**接线）= **我**；㉝ **整条归我**（2026-07-16 用户改定：修完要靠它跑手动/自动 e2e 回归）——但**做成 world 通用机制**：chat 消息渲染支持「链接解析成气泡」的注册式扩展（plugin 声明链接模式 → 气泡渲染器 + 点击动作），装了 kanban plugin 时分享链接不显示原链接、直接渲 kanban 气泡、点击跳转/挂载；机制通用、kanban 是第一个消费者，其他 plugin 后续可复用。⑯ ws 口径 = **Allen**。

---

## 二、六组之外的独立项

| 项 | 定性 | 修法 | 归属 |
|---|---|---|---|
| ㉕ drop 重定义 | 产品语义改写（非 UI 问题）：drop = 北极星不达标的**跟踪标红**，非删除 | `handle_drop_subtree`（kanban.ex:358-397）改非破坏标记：子树打 `dropped: true` + reason/at/by，不动 nodes；`:drops` 历史加 reason；授权改节点认领人 or `board_admin?`；`handle_get_tree`（:559）投影带标；前端红框 | behavior + 红框渲染（KanbanCanvas）= **我（本 PR）** |
| ㉛ 装 sw 面 + 存模板 | 机制全在（install/retract #1245/`save_session_template`/`installed_definitions` installation.ex:470），缺会话设置面 | 已装列表 + 多选装卸 + "保存为 template" 接线 | **zyli**（会话管理面，非 kanban 界面） |
| ⑲ 删板 UI | 机制在（建板人 Manage cap；#1411 retire 语义） | `kanban.delete_board` dispatch 动作（校验 Manage → `Domain.Agent` retire + `Mount` 逐行 unmount，**不直调 terminate**）；导图列表删钮+确认框（Kanban.tsx） | 动作 + UI 都 = **我（本 PR）** |
| gap3 残留（cc） | #1434 已修 prompt+skill（R1/R2）；**#1323 headless-MCP 仍未进 main**——助手有钥匙也没工具 dispatch | #1323 落 main + config_dir `.mcp.json` 读取 | **gaga handoff** |

---

## 三、按负责人切 PR（归属重切版）

分工原则（用户定）：**我（jjkysy）= kanban 自包含全部**（plugin + sw 业务 + kanban 前端）；**zyli = 除 kanban 外的 world 前端 + 推送订阅/分发基建**；**gaga = agent runtime**（cc/凭证/provisioning）；**Allen = 系统层面的权限/契约/rule 决策**。

| # | PR | owner | 内容 | 依赖 |
|---|---|---|---|---|
| 1 | **本 PR #1374 收尾** | 我 | 已修 ⑤⑥⑦⑧⑨ 收口 + **债③** receive 搬 plugin + **⑳** assistant 降级为增强 + **㉕** drop 标红（behavior + KanbanCanvas 红框）+ **⑲** delete_board（动作 + 删板 UI）+ **⑮** dev.exs 一行 + **全部 kanban 前端**：㉗ 面板规格重做 + ㉓㉖㉚㉞ + ㉙ 分享框两选项 UI + ㉘/㉒-① 看板数据刷新的 kanban 侧（订 board topic + 重拉）+ ㉝ **整条**（world 通用链接-unfurl 注册机制 + kanban 气泡渲染 + 点击跳转/挂载）+ Kanban 组件深色 token 化 + 证据/文档收敛（PR 收尾规矩） | ㉘/㉒-① 前端消费依赖 zyli 订阅基建接口（payload 约定先行可并行） |
| 2 | **推送环发布侧**（可并入 #1374 或独立小 PR，我） | 我 | X1 发布侧：membership `:notify` + kanban 写 action `:emit`（含 payload 约定文档） | 无；与 zyli 基建配对 |
| 3 | **join 补发**（独立 PR，我，**等 Allen D1**） | 我 | X2 入口1：join hook（member view caps + mount operate 补发），domain_session 通用机制零 kanban 字面 | Allen 拍 rule 名/授权面 |
| 4 | **分享闭环二期**（独立 PR，我） | 我 | ㉙ 分享到会话 dispatch + 规则8 `request_edit` action + ㉝ `claim_shared` 落点修正 | PR1（receive 归宿）+ PR2（推送）+ Allen D4（receive 签名的 ws 口径） |
| 5 | **handoff → zyli** | zyli | **world（非 kanban）前端**：推送环订阅/分发基建（⑰㉒㉘ 的基建半边）+ ⑰ 会话列表/成员面板刷新 + ㉒-② tab 深链 + ⑱ Conversation 层深色 + ⑫ 向导按钮 + ⑩㉑ 投影/向导提示 + ㉛ 装 sw 面/存模板 + ⑭ 邀请码管理面 + ㉝ chat unfurl 渲染半边 + ⑬ dev 前端 | 基建与我 PR2 以 payload 约定为接口 |
| 6 | **handoff → gaga** | gaga | **agent runtime**：#1323 headless-MCP 落 main + cc 凭证供给面（⑩ 静默 skip 上游 = `CredentialPrecondition`/绑定面 + 补物化 + 可观测） | 无 |
| 7 | **handoff → Allen（决策单，不实施）** | Allen | D1 join 补发 ambient rule 家族（含 transient ctx-cap 用法 + #1394 永久线）；D2 ⑥ create_agent rule 追认（三选项）；D3 ㉜ tab 门控 view-cap 契约；D4 ⑯ 两条分享路 ws 口径；D6 债①②分层永久线（**mount 折 CompositionBinding**）；附带 D5 ⑪ dev boot-scan 口径（#1224） | — |

handoff 文件：`docs/together/2026-07-16/handoffs/{allen-decisions,zyli-world-frontend,gaga-agent-runtime}.md`。

## 四、深扫：plugin_kanban 之外的 kanban 硬编码（2026-07-16，老 kanban 已被 #1425 合入 main 后）

口径：`grep -rn "kanban" apps/ --include=*.ex -i | grep -viE "plugin_kanban|test"`，47 个文件命中；另加前端 `apps/ezagent_plugin_world/assets/src/components/{Kanban,KanbanCanvas}.tsx`（债②前端半边）。逐条按**可剥 / 暂留（理由）/ 不动**三列判。

### 可剥（本 PR / 短期）

| 处 | 现状 | 剥法 |
|---|---|---|
| ezagent_web `kanban_share_controller.ex`（13 处业务字面：`@assistant_role "kanban-assistant"`、`resolve_target_session` 挑首个带 assistant 的 session、直调 `Mount.mount`） | 债③，P13 违反 | **本 PR**：业务搬 kanban plugin `receive_shared_board`（plugin 向下调 domain `Mount.mount` 合法，plugin→domain 是允许的依赖箭头，mix.exs 有先例注释）；controller 瘦成 verify token（Phoenix.Token 属 web 层留下）+ 调 plugin + redirect；router.ex:261 receive 路由留（纯 transport） |
| domain_session `board_provision.ex` 里的 kanban **默认值**（`@default_assistant_role "kanban-assistant"` :176、只读动作 `get_tree/export_markmap` :177、doc 示例） | 债①残余：模块本体 #1425 后已参数化成"通用挂载 infra 的瘦 kanban 消费者"（:3 自述），字面只剩默认值 + 文档 | 短期可做：默认值上提到调用方（现调用方 world `kanban_actions.ex:380` 与分享链，债③ 后都是 kanban 侧代码），模块变零 kanban 字面；本体见「暂留」 |

### 暂留（理由）

| 处 | 现状 | 为什么等 |
|---|---|---|
| domain_session `board_provision.ex` 本体（create/pull/forward glue + `{:rule, :socialware_runtime_provision, creator}` 一次性 rule-mint） | 债① | 把建板策略搬回 plugin 的前置 = ① plugin 拿到合法的建-agent 授权路（Allen D2）② `Mount` 可 dispatch 化 / 折 `CompositionBinding`（Allen D6）；rule-mint 点搬进 plugin = plugin 持 rule authority（#154 review 面）。**权限改造前 Mount 保留，本体不动** |
| world `plugin_page_registry.ex` kanban 条目 + `@kanban_actions` 白名单（:28-41） | 债②：注册表**机制**已通用（kanban 曾是 world 写死特例，2026-07-09 迁入注册表），但**条目**仍是 world 手写 | 条目改由 plugin 声明贡献 = plugin-UI 注册机制（Allen D6 平台线）。过渡：白名单随我们 PR 新动作（delete_board/claim_shared/request_edit）同步，**归我方维护** |
| world `kanban_data.ex`（36 处）/ `kanban_actions.ex`（71 处）+ `Kanban.tsx`/`KanbanCanvas.tsx` | 债②：kanban 读模型/动作面/React 组件物理住 world | 物理搬 plugin 同等 D6（plugin 贡献 React 组件 + 数据 reader 的机制不存在）；**逻辑归属已重切给我方**（本轮所有 kanban 前端改动都发生在这几个文件），不再扩散新字面 |
| world `conversation_data.ex:20` `@native_react_ids`（kanban_board→"kanban"）+ `conversation_actions.ex:542` `view_switch_updates` "kanban_board" 特例 + `state_contract.ex:75` "kanban" 页面项 | native React renderer 的写死映射，是 world:state 契约的一部分 | 同属 plugin 贡献组件机制（D6）；单点剥会破 state_contract 契约测试，等机制一次迁 |
| ezagent_web `router.ex` `/plugins/kanban` 4 行 live 路由（:62-63/:105-106） | 页面路由字面 | 路由声明化属 D6；transport 层字面无业务逻辑，危害低 |

### 不动

| 族 | 处 | 理由 |
|---|---|---|
| hello 组合业务（gaga/hello 侧，列出即可） | plugin_hello：`kanban_delegation.ex`（33 处）、`hello_dispatcher.ex`（`delegate_to_kanban` 动作）、`kanban_published_read.ex` + `published_board_ref.ex`（port）、prompts/generator/router/application；ezagent_web：`kanban_published_read_adapter.ex`、`hello_delegation_controller.ex` + continuation | hello→kanban 委派/发布只读引用是 **hello 侧的跨-sw 组合业务**，不是 kanban 泄漏；port/adapter 姿势本身正确（"Kanban remains the sole board-data owner"）。将来债③/分享闭环搬 plugin 后，adapter 的 supplier（现调 `World.KanbanActions.share_link`）跟着换即可 |
| 纯注释/文档举例（~25 文件） | core（role_seed_hook/socialware_seed/arch.scan/sandbox/recipe）、domain_agent（recipe_resolver/grant_recipe_caps/agent_passive_attributes/default_agent_seed 的 moduledoc 示例）、domain_ui（session_view/session_view_registry）、domain_session（installation/mount/manifest_seed/shipped_manifest/session_creator 注释）、plugin_native/py/kb/cc、world（navigation/routes/slot_registry/workspace_plugin_data/ui_surface_provider/world_live 注释） | 零行为字面，kanban 只作历史/示例引用；剥了没收益 |

**结论**：真业务泄漏**现在可剥 1 处**（债③ share controller，本 PR 做）+ **半处**（BoardProvision 默认值上提，本 PR 顺手可做）；**暂留 5 组**（全卡 Allen D2/D6 的平台机制：plugin 建-agent 授权路、Mount dispatch 化、plugin-UI 注册）；**不动**：hello 组合一族 + ~25 文件纯注释。

**风险提示（沿上一版仍有效）**：
1. join 补发是新 ambient rule（#154 面），抢跑=又一轮 cap 返工——PR3 严格等 Allen。
2. ㉜ step2 谁"顺手"把 `applies_to?` 改恒 true 就撞 T2-2b 契约。
3. PR2 的 `:emit` 别做成 inbound dispatch（P14）；订阅退订照 PTY 泄漏教训（world_live.ex:149-155 注释）。

## 修正(2026-07-17,用户挑战+skill-1 实证):债② 砍一半,「暂留5组」改判
用户记忆正确——world 注册机制覆盖度比上轮判的深:dispatch 层已是注册表反射(world_live.ex:297-306 经 PluginPageRegistry 动态调 actions_module.handle_dispatch)、数据 reader 有 @pages.data_builder 口、tab 注册本在 plugin 侧(BoardView)。
- **升格为本轮可做**:`kanban_actions.ex` + `kanban_data.ex` 搬进 plugin_kanban(world 剩 @pages 一条注册数据 + mix dep,hello 先例;排在后端/前端批落地后做防冲突;注意 world_live state_for_route 编译期 unroll 依赖 dep 方向)。
- **D6 缩窄为三处真缺口**:① @pages 条目 plugin 自声明(UiSurfaceProvider follow-up,registry moduledoc 自陈);② 前端插件 JS 分发(Kanban.tsx 出 world bundle,或 iframe 降级);③ conversation tab 三处特判(native 映射 conversation_data.ex:20/switch_view conversation_actions.ex:542-559/Conversation.tsx:842)。BoardProvision 本体仍等 Mount 可 dispatch(D6 原判不变)。
