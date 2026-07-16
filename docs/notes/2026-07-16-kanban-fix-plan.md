# kanban 修法计划 v2 —— X/Y 方向纠正版（2026-07-16，skill-1 重审）

**术语纠正**：本版遵循用户口径 —— **Y = 看到的现象，X = 根因**。上一版（e015e630d）把标签用反了（X=现象、Y=真问题），方向也因此偏成"从现象归并"；本版从根因（X）出发定修法。所有锚点现读代码核实（HEAD `e015e630d`，代码同 `743ed6178`，其上只有 docs commit）。

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
- **归属**：发布侧（domain_session notify + kanban plugin emit）= **我，独立 PR**；订阅/处理/前端侧 = **zyli handoff**。两侧以 payload 约定为接口（见 zyli handoff §接口约定）。

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
- **归属**：1 = **我（本 PR）**；2 = **zyli**（world 投影/向导）；3 = **gaga handoff**。

### X4 —— 看板面从 demo 长出来，没有经过设计规格

- **Y（现象们）**：⑫ 向导按钮点不到、㉓ 本图配置块、㉖ 改名藏 prompt/节点框截断、㉗（= 用户给的整面规格）、㉚ 剪贴板静默失败、㉞ 前半"✓已保存"、⑱ 深色主题白屏刺眼。
- **X（一句话）**：这张面板没被设计过，是 demo 顺手长的；㉗ 就是规格书 —— **修 = 按规格一次重做，不是七个点补丁**。
- **从 X 修**：一个前端 PR 按 ㉗ 规格重做节点面板（Kanban.tsx:519-596 产物区：「添加」+下拉 链接/内容/画图/附件、去 SHA 入口、补附件上传 `kanban.attach_upload` 通道已在、每产物删除钮 `detach_artifact` 动作已有 kanban.ex:536、「内容」弹大框 md 编辑器照 ExcalidrawModal 形态）+ ㉓ 移除本图配置块（:162-164, :265-280；Miro 板名只在 sync_miro 弹窗填 :212）+ ㉖ 标题就地编辑（替代 :596 `window.prompt`）/画布节点框自适应 + ⑫ 向导 max-height/按钮固定底（SessionsTable.tsx:180-255）+ ㉚ clipboard 回退+真实反馈（:63 附近）+ ⑱ 硬编码浅色换 token（Conversation.tsx:863/:684/:1724 及 Kanban/KanbanCanvas 同类；root data-theme 机制现成 root.html.heex:21）+ ㉞ 摘 :661。
- **只修 Y 的诱惑**：逐点打补丁 —— 每个补丁都会在按规格重做时返工；或"顺手"改 behavior 动作签名（attach_code_file/set_board_config **动作保留**，只动 UI 入口）。
- **归属**：**zyli handoff**（整包）。

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
  3. **㉝ unfurl**：Conversation 渲染识别 `/socialware/kanban/claim?token=` → 渲成 ㉙ 同款气泡；点击带**当前 session_uri** 走 `kanban.claim_shared`（修 controller 落点错位）。
  4. **规则8 申请编辑**：板新 action `request_edit`（pending 记进 `:kanban` slice）→ 批准气泡发到 mount 表 access=operate 的"编辑 session" chat（C4：批准人=版主 data_owner）→ 批准即 `Mount.mount` 升级 operate。可拆两步（先板面内批准，气泡后补）。依赖 X1 推送 + ㉙ 气泡形态。
  5. **⑯ ws 口径**：`forward_board` 有 `same_workspace` 硬守卫（board_provision.ex:267,:292）而链接分享路无 ws 检查——两路口径不一，**统一方向归 Allen**（用户倾向：系统支撑就放开）。
- **只修 Y 的诱惑**：在 controller 里继续加 unfurl/气泡逻辑（P13 债滚大，将来搬家做两遍）；或先做前端 unfurl 再搬业务（同样做两遍）。
- **归属**：plugin 侧动作（1、4 的 behavior、2 的 dispatch 接线）= **我**；气泡/unfurl 渲染 + 点击接线 = **zyli**；⑯ 口径 = **Allen**。

---

## 二、六组之外的独立项

| 项 | 定性 | 修法 | 归属 |
|---|---|---|---|
| ㉕ drop 重定义 | 产品语义改写（非 UI 问题）：drop = 北极星不达标的**跟踪标红**，非删除 | `handle_drop_subtree`（kanban.ex:358-397）改非破坏标记：子树打 `dropped: true` + reason/at/by，不动 nodes；`:drops` 历史加 reason；授权改节点认领人 or `board_admin?`；`handle_get_tree`（:559）投影带标；前端红框 | behavior = **我（本 PR）**；红框渲染 = **zyli** |
| ㉛ 装 sw 面 + 存模板 | 机制全在（install/retract #1245/`save_session_template`/`installed_definitions` installation.ex:470），缺会话设置面 | 已装列表 + 多选装卸 + "保存为 template" 接线 | **zyli** |
| ⑲ 删板 UI | 机制在（建板人 Manage cap；#1411 retire 语义） | 我提供 `kanban.delete_board` dispatch 动作（校验 Manage → `Domain.Agent` retire + `Mount` 逐行 unmount，**不直调 terminate**）；前端删钮+确认框 | 动作 = **我**；UI = **zyli** |
| gap3 残留（cc） | #1434 已修 prompt+skill（R1/R2）；**#1323 headless-MCP 仍未进 main**——助手有钥匙也没工具 dispatch | #1323 落 main + config_dir `.mcp.json` 读取 | **gaga handoff** |

---

## 三、按负责人切 PR

分工事实：**我（jjkysy）= kanban plugin + sw 业务（本 PR #1374）**；**zyli = world 前端**；**gaga = AgentRuntime 域（cc/凭证/provisioning）**；**Allen = 平台架构决策**。

| # | PR | owner | 内容 | 依赖 |
|---|---|---|---|---|
| 1 | **本 PR #1374 收尾** | 我 | 已修 ⑤⑥⑦⑧⑨ 收口 + **债③** receive 搬家 + **⑳** assistant 降级为增强 + **㉕** drop 语义 + **⑲** delete_board 动作 + **⑮** dev.exs 一行 + 证据/文档收敛（PR 收尾规矩） | 无 |
| 2 | **推送环发布侧**（独立 PR，我） | 我 | X1 发布侧：membership `:notify` + kanban 写 action `:emit`（含 payload 约定文档） | 无；与 zyli 订阅侧配对 |
| 3 | **join 补发**（独立 PR，我，**等 Allen**） | 我 | X2 入口1：join hook（member view caps + mount operate 补发），零 kanban 字面 | Allen 拍 rule 名/授权面 |
| 4 | **分享闭环二期**（独立 PR，我） | 我 | ㉙ 分享到会话 dispatch + 规则8 `request_edit` action（气泡 UI 归 zyli 侧） | PR1（receive 归宿）+ PR2（推送） |
| 5 | **handoff → zyli** | zyli | 推送订阅侧 + ㉒-② 深链 + X4 面板规格整包 + ⑩㉑ 投影/向导 + ㉛⑲⑭ 管理面 UI + ㉙㉝ 气泡/unfurl 渲染 + ㉕ 红框 + ⑬ dev 前端 | 部分依赖 PR2 |
| 6 | **handoff → gaga** | gaga | #1323 headless-MCP 落 main + cc 凭证供给面（install skip 上游 + 可观测） | 无 |
| 7 | **handoff → Allen（决策单，不实施）** | Allen | join 补发 rule 家族（`:socialware_member_views`/`:socialware_runtime_provision` 进 Decision Log + transient ctx-cap 用法）+ #1394 永久线；⑥ create_agent 三选项；㉜step2 T2-2b tab 门控；⑯ 分享 ws 口径；⑪ dev boot-scan 口径（#1224）；债①②分层永久修 | — |

handoff 文件：`docs/together/2026-07-16/handoffs/{allen-decisions,zyli-world-frontend,gaga-agent-runtime}.md`。

**风险提示（沿上一版仍有效）**：
1. join 补发是新 ambient rule（#154 面），抢跑=又一轮 cap 返工——PR3 严格等 Allen。
2. ㉜ step2 谁"顺手"把 `applies_to?` 改恒 true 就撞 T2-2b 契约。
3. PR2 的 `:emit` 别做成 inbound dispatch（P14）；订阅退订照 PTY 泄漏教训（world_live.ex:149-155 注释）。
