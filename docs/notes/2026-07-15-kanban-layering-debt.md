# kanban 改版分层债 + gap3 平台缺口（#1374/#1376 过渡照现状交，永久修交 Allen 线）

真机 e2e review（2026-07-15）暴露 4 处「够得到所需 API 的层 ≠ 该拥有这逻辑的层」——业务被塞进 infra/UI/transport 层。#1374/#1376 作**过渡**照现状落地；干净修法都要动分层/平台，与 Allen 的永久 Entity 双向-caps 模型（#1394）是一条线。

## ① BoardProvision = kanban 业务在 domain 层
- **现状**：`apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex` —— 带 kanban 字面（`board` / `kanban-assistant` role / `[:get_tree,:export_markmap]`），却在 domain_session。
- **为什么**：直调 `Ezagent.Workspace.create_agent`（domain_workspace）+ `Ezagent.Socialware.Mount`（domain_session）等**域 API**；kanban plugin 在域之上够不到，塞进 domain_session 才有访问权。
- **干净修**：kanban plugin 自己拥有建板 glue，**走 dispatch**（P14：dispatch 建-agent + mount 动作），domain_session 只留通用 `Mount`。前置 = **`Mount` 变成可 dispatch 的动作**（现是直调 API）。→ Allen 永久模型。

## ② kanban view 在 world_plugin
- **现状**：`apps/ezagent_plugin_world/lib/ezagent/world/{kanban_data,kanban_actions,conversation_data}.ex` + `assets/src/components/Kanban.tsx` —— kanban UI/数据/动作在 world，不在 kanban plugin（`kanban_render.ex` 在 kanban plugin）。大部分**既有**，本次 T6 顺着扩。
- **为什么**：world_plugin 是 session UI 宿主（React app / Conversation / plugin-page-registry / world:dispatch），托管所有 plugin UI。
- **干净修**：kanban plugin 自包含自己的 view，world 只做 UI 壳/挂载点（需 plugin-UI 注册机制让 plugin 贡献 React 组件 + 数据 reader，而非 world 内置 kanban 细节）。

## ③ share/接收业务在 web controller
- **现状**：`apps/ezagent_web/lib/ezagent_web/controllers/socialware/kanban_share_controller.ex` —— controller 里做了业务（解析接收者 session + `Mount.mount`），不只 transport。
- **为什么**：接收是 web 路由（点链接=HTTP）→ Phoenix controller 合理；但业务塞进了传输层，违反 **P13（Phoenix 是 transport 不是 fullstack）**。
- **干净修**：controller 变**薄** —— verify token 后 **dispatch 一个 kanban plugin 的「receive shared board」动作**，接收者-session 解析 + mount 在 plugin/域做。**这条不动平台就能搬**（controller→薄 dispatch + kanban plugin 加 receive 动作）。

## ④ gap3：cc-headless 没把 recipe-prompt/skill/工具桥送进 cc turn（chat 中心 operate 卡这）
机制全通（助手有 cap 时 dispatch `kanban.get_tree` 成功；cap→dispatch→manager per-node 过滤 都在）。卡在 cc-plugin spawn 接线 3 个 code gap：
- recipe `system_prompt` 没 thread 进 sidecar turn：`apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex:268`（取值空）+ `sdk_sidecar.ex:264`（sidecar env 无 `EZAGENT_CC_SDK_SYSTEM_PROMPT`）。
- skill 没加载：`apps/ezagent_plugin_cc/priv/python/ezagent_cc_sdk_worker.py:99-108` `setting_sources=[]`；助手 cwd 无 `scripts/`，相对路径 resolve 不到。
- 助手 cwd `.mcp.json` 桥指向**已删 worktree** `worktrees/sw-kanban/.../ezagent_mcp_bridge.py` → esr-bridge MCP 起不来 → 零看板工具。
- **归属**：cc-plugin（MCP/cc-dispatch 规范化线，Allen/gaga）。非 kanban 业务、非 recipe/skill config（recipe 文本对，没被送进 turn）。

## 共同根因
平台没给 plugin 干净的路（plugin 够不到域 API / world 托管 UI / HTTP 落 controller / cc-headless 不 thread prompt·skill）→ 业务被塞进 infra·UI·transport·cc 层。**③ 不动平台可先搬；①②④要动分层/平台，交永久线。**

## ⑤ 测试发现的功能 bug:装 kanban 后 owner 看不到看板 tab(render cap 没授登录用户)
- **现象**:普通用户(owner,非 admin)建 session 选 kanban → **看不到「看板」tab**;admin 能看(wildcard 绕过 cap)。
- **根因**:看板 tab(`BoardView` SessionView)门控 cap = `cap(:session, Ezagent.ActionSet.KanbanRender, :kanban_render, session_instance, workspace)`(`kanban_render.ex:51 required_caps`)。session 安装时,这个 view render cap **只经 `installation.ex:307 anon_view_caps` 给匿名访客铸**(web_anon_access 的 public 视图),**没给登录的 installer/owner 和成员**。→ owner 无此 cap → tab 隐藏。
- **修法**:session 安装时,给 installer/owner(和成员)也授 declared views 的 render cap(照 `anon_view_caps` 的 `view_render_caps` 逻辑,granter=owner/admin,走 Cap.issue)。归属:socialware 安装的 view-cap 授权(domain_session installation),平台侧。
- **临时**:后台给测试用户手工铸 render cap 让测试继续(非产品修复)。
- **✅ 已修(2026-07-16,installer/owner 部分)**:`Installation.grant_installer_view_caps/2`(通用,零 kanban 字面,ALL 已装 definition 的 declared views,经 Grant chokepoint `{:rule, :socialware_install_views, installer}`),挂在 `SessionCreator.finalize_fresh_session` + `verify_or_recreate` 两个 install 点。测试 `installer_view_caps_test.exs`。**TODO(成员)**:后加入成员无 view-cap 补发点(join 流程只发 session 参与 cap),待定补发机制。

## ⑥ installer/owner 没拿到 `create_agent` cap → UI 建不了板(与 ⑤ 同类)
- **现象**:owner 在看板 tab 填「新导图名」点「+」→ 无反应、板没建。
- **根因**:UI「建导图」dispatch `kanban.create` → `create_kanban`(kanban_actions.ex)→ `workspace.create_agent`(建 kanban-manager board agent),需 `cap(:workspace, Workspace, :create_agent)`。owner(installer)**没这个 cap**(日志 `create_agent` authz=`denied :unauthorized`)。
- **根因同 ⑤**:session 安装只给 owner session 管理 cap,没给「用 kanban 所需的 cap」(create_agent 建板 + kanban_render 看 tab)。
- **修法**:session 安装时给 installer/owner 授建板所需 cap(scoped `create_agent`,或让 UI 建板走 BoardProvision 用 owner 授权路)。归属:socialware 安装的 owner-cap 授权(domain_session)。
- **⛔ 调查完毕,待 Allen 决策(2026-07-16)**:普通用户全链路**没有任何 `create_agent` 授点**(workspace `add_member` 只授 `:create_session`,`behavior/workspace.ex handle_add_member`;registration 无);`Ezagent.Domain.Agent.materialize_*`(#1411)是 trusted-internal 声明成员物化边界,**无 CapBAC 门**,给用户触发的建板用=绕过授权,不是干净路。三个选项:(a) workspace 成员一律授 scoped `create_agent`(照 `create_session`);(b) 装带 agent-host 的 socialware 时按 definition 声明给 installer 授 workspace-scoped `create_agent`(`{:rule,…}`,但=装即自升权);(c) 平台 rule 内联 authority 只放行「passive data-host agent」建板特例(ambient authority,#154 review surface)。全是平台级授权决策,未实施。

## ⑦ board owner 建不了根节点(建根硬要 admin wildcard,不认 board owner)
- **现象**:board owner 在自己建的板上「建根节点」→「无权限,需 admin」。
- **根因**:`kanban.ex:265` `parent_id == nil and not admin?(ctx) -> {:error, :forbidden}`;`admin?(ctx)`(`kanban/shared.ex:156`)**只认 `%Capability{kind: :any}` wildcard = 全局 admin**,不认 board 的 data_owner。→ board owner(非 admin,只持 board instance-precise operate cap)建不了根。
- **矛盾**:与「owner 可编辑所有节点」模型冲突(用户 2026-07-14 定的规则)。owner 应能建根 + 全编。
- **修法**:建根授权改 `admin?(ctx) or caller == board data_owner`(handler 里 `Kanban.data_owner(instance(self))` 拿 board owner 比对 ctx.caller)。归属:kanban 业务(kanban plugin,我范围)。

## ⑧【真根因·统一 ⑤⑥⑦】owner 建板只拿到 `Manage` cap,没拿到 `Kanban` operate cap → 读/写自己的板全 unauthorized
- **现象**:owner 刷 testboard 看板 tab **一片空**(连后台以 admin 建好的根节点都看不到)。
- **诊断**:owner 在 `entity://system/agent/testboard` 上持的 cap = `%Capability{kind: :agent, behavior: Ezagent.ActionSet.Manage, action: :any}`(agent 生命周期:terminate/destroy)。而 `kanban.get_tree`/`add_node` 要的是 `behavior: Ezagent.ActionSet.Kanban`(required_caps kanban.ex:220,kind `:any` 运行时替 `:agent`)。**behavior 轴对不上**(Manage ≠ Kanban,都非 `:any`)→ owner 的 `get_tree` dispatch = `{:error, :unauthorized}` → UI 读回空树(fail-safe)。
- **统一根因**:`Workspace.create_agent` 给建者铸的是 **Manage**(管 agent),没铸 **Kanban operate cap**(操作看板 = `cap(:agent, Kanban, :any, board)`,正是 #1376 mount cap 的形)。所以 owner 能「管」这个 agent(销毁),却不能「用」这块看板(读/加/改节点)。⑤(看 tab 的 session render cap)/⑥(建板的 workspace create_agent cap)/⑦(建根 admin-gate)+ 本条(板级 operate cap)= 四个各自独立缺失的 cap,统一症状「owner 拿不到用自己 kanban 所需的 cap」。
- **修法**:装 kanban / chat 建板后,给 owner(和 assistant「手」)铸指向该 board 的 Kanban operate cap(走 #1376 `Mount.mount`/`CompositionCaps.mint_cap`,granter=板主人)。这正是 #1374 chat-建板要接的「发钥匙」动作(plan 第 3 件)——当前 UI 建板走的老 `create_kanban` 只 create_agent+Manage,漏了铸 operate cap。归属:kanban 建板业务(#1374)+ mount infra(#1376)。
- **✅ 已修(2026-07-16,create_board 路)**:`BoardProvision.create_board/5` 现在给**建板人**(owner_ctx.caller)也经 `Mount.mount/6` 挂全动作 operate 钥匙(granter=板主人自己,`{:held_by, owner}` 自路径,落挂载表可 reconcile),返回加 `:creator_minted`。测试 `board_provision_grant_test.exs`。**TODO(join 补发)**:`Mount.reconcile_session_mounts/1` 只按挂载行重发**已记录 grantee**,覆盖不了「新成员进 session 补发」;新成员 join 时的 board-key 补发机制待定。**注**:UI 建板(world `create_kanban`)仍走老直调 `Workspace.create_agent` 路(不发钥匙)——改走 `create_board` 依赖 ⑥ 的 create_agent 授权决策(Allen)。

## 修复进展(2026-07-16,collab 改版落地时)
- **⑤ 已修**:`Installation.grant_installer_view_caps/2`(installation.ex,通用零业务字面,tag `{:rule,:socialware_install_views,installer}`),挂 session_creator fresh+verify 两路。**成员 join 补发仍缺**(join 只发 session 参与 cap,后加入成员看不到 view tab)→ TODO。
- **⑥ 已修(过渡)**:`BoardProvision.create_board` 走 `{:rule, :socialware_runtime_provision, creator}` 一次性 scoped create_agent cap(Cap.issue chokepoint,transient 不落库),边界=①建板人须本 session 成员 ②只造 recipe `passive:true` 的 data-host。world create_kanban 改走 create_board(session-scoped)。**留 Allen**:rule 名进 Decision Log;「transient ctx-cap 不落库」用法确认(现有 rule-mint 全持久化,这是首个 transient 用例);要不要 workspace 级算力开关。
- **⑦ 已修**:behavior 层 `board_admin?`(版主=data_owner 或全局 wildcard),建根门移除(collab 模型:任何成员可加,自动认领)。
- **⑧ 已修**:create_board 给建板人也经 Mount.mount 发全动作 operate 钥匙(granter={:held_by,owner} 自路径),落挂载表。**成员 join 补发 board 钥匙仍缺**(reconcile_session_mounts 只重发已记录 grantee)→ TODO,与 ⑤ join 补发同一个洞:**「新成员进 session 拿到该 session 已挂资源的钥匙」没有机制**,建议并入 Allen #1394 Entity 双向-caps/mount 永久线。

## e2e 新挖(2026-07-16,两账号真 UI,详见 docs/e2e/2026-07-16/README.md)
- **⑨ 已修**:Mount.provision 建宿主 5s 超时半途崩→孤儿板(agent建成零钥匙零挂载行);deadline 30s 修复。
- **⑩ 记录**:cc-headless 无凭证源→install 静默跳过角色,UI 无提示(仅 server log)。归 install/UX 面。
- **⑪ 记录**:dev 无 socialware 发布车道(boot scan prod-only;mix import 撞运行 server 的 _build)。dev 体验债。
- **⑫ 记录**:建会话向导「创建」按钮折叠线下,不 scroll 点不到。前端 UX。
- **⑬ 记录**:dev 前端骨架屏(vite 冷启 + WS 退 longpoll 106:4),world React 挂载偶发失败。dev-env 债,查 WS 被拒原因。
- **⑭ 改记(2026-07-16 用户纠正)**:跨用户协作的正路 = **邀请码注册**(邀请码携带目标 workspace,人「出生」进 ws;registration_controller.ex:8)。`workspace.add_member` 动作存在但全 UI 零调用点——**按邀请码模型这个接口可能完全不需要**(成员不是后来「加」进 ws 的),待审的是接口存在性而非补 UI;真正缺的 UI 是「邀请码的铸造/管理面」(现只有 mix ezagent.invite,in-VM,task 自注 UI surface 是 follow-up)。归属:workspace 管理面。
- **⑯ 业务边界纠正(2026-07-16 用户定)**:**分享业务 = 同 workspace 跨会话**,不存在「跨 ws 分享」业务。e2e 里 owner→viewer 的跨 ws 只读挂载(docs/e2e/2026-07-16)证明了机制上可达,但**超出业务设定**——分享 token/`Mount.mount` 现在不检查收方 workspace,是否应收紧到同 ws(fail-closed)待产品/Allen 定;后续 e2e 的分享场景按同 ws 两账号(邀请码同 ws)重验。
- **⑮ 记录(2026-07-16 手动测试)**:确认信链接域名在 dev 下仍是生产 `app.ezagent.chat`(config.exs:147 `:verification_base_url` + runtime.exs:36 `EZAGENT_PUBLIC_HOST` 默认值),dev 用户点信里链接打不开——dev.exs 应覆盖为本地 host(或从请求 host 派生)。小修,归 email/web 配置。
- **⑰ 记录(2026-07-16 手动测试)**:成员变动无实时推送——A 把 B 加进会话/工作区后,B 的界面(会话列表/成员面板)不自动刷新,要手动刷新才见。锚:WorldLive 只在**自己打开**会话时才订阅该 session topic(world_live.ex:106 ensure_session_subscribed + :41 subscribe_global_inbound 只订自己 inbound)——「我被加进了新会话」这类 membership 事件没有推到被加者的 LiveView。修法方向:membership 变更 broadcast 到被加者的 per-user topic(subscribe_global_inbound 已有 per-user 通道可复用)。归属:world 实时面。
- **⑱ 记录(2026-07-16 手动测试)**:深色主题下进入某个 session,页面变白刺眼——主题机制是 root `data-theme`(root.html.heex:21)+ tailwind dark variant(styles.css:17),但会话/看板面存在不吃 token 的硬编码浅色(待逐个排:Conversation/Kanban 组件 bg-white/固定色类)。归属:world 前端主题一致性。
- **⑲ 记录(2026-07-16 手动测试)**:没有删除已存在板子的 UI——板=kanban-manager agent,建板人持 Manage cap(terminate/destroy 权在手,#1411 后走 Domain.Agent.retire 语义命令),但看板面/导图列表没有任何「删板」入口;孤儿板(如 demo-board)也无清理路。归属:world 看板面 + 板生命周期 UI。
- **⑳ 改记(2026-07-16 用户纠正框架)**:**建板人钥匙 = kanban plugin 基线**(无论有没有装 sw,建板必发建板人钥匙——测的是 plugin 不是 sw);**assistant 钥匙 = sw 增强**(配上 kanban sw 才多发一把给 assistant)。现实现把增强做成硬前置(`create_board` 解析不到 assistant 整体 fail-closed)——**方向反了**。修法:创建宿主+发建板人钥匙为主链;有 assistant(sw 就位)才附加发 assistant 钥匙,没有则跳过(留待补发)。归属:BoardProvision(建板 glue),plugin/sw 职责分层。
- **㉑ 记录(2026-07-16 手动测试)**:会话面的「kanban-assistant · 未装载:缺少 Claude 凭证」横幅读的是 install 时跳过记录(持久),**不随后补成员 reconcile**——后台补了 native assistant 进成员表后横幅仍报未装载(失真)。修正 ⑩ 表述:向导无提示,会话面有横幅,但横幅不刷新。归属:install 状态投影/会话面。
- **㉒ 记录(2026-07-16 手动测试)**:建板后**一整套刷新/状态问题**——①建板成功后本人界面不自动刷出新板(要手动刷新,与 ⑰ 同族:成员/挂载变化无实时推送);②手动刷新后落在**对话 tab** 而非看板 tab——tab 切换是客户端 `session.view.switch`,URL 无 view 深链(T6.4 已知设计),刷新即丢 tab 态。修法:建板走 push_event 刷 board_state(本就有,查为何没生效)+ tab 态进 URL(view 深链)或 session 存储。归属:world 前端状态/实时面。
- **㉓ 记录(2026-07-16 用户定)**:板侧边栏「本图配置」块应**整体移除**——①GitHub 仓库字段不需要(去gh 进一步:板级不留 repo 配置;节点级 register_pr/attach_code_file 纯数据链接另说,repo 缺失时可在登记时就地问);②Miro 配置只在「导出到 Miro」时弹窗填(sync_miro 弹框已实现,板名持久配置块删掉)。归属:world Kanban.tsx(下一批前端修)。
- **㉔ 记录(2026-07-16 用户定)**:**删除和 drop 合并为一个功能——不需要独立的 drop 了**。collab 模型规则5「删除=drop 子树」本就是一件事:UI 上「删除(含子树)」和「drop」两个入口重复,保留删除(整树己认领/未认领校验+版主兜底),drop 独立入口/语义(记 drop 历史的 :drops)去掉或并入删除。涉及:kanban behavior(drop_subtree vs remove_node 双动作收敛)+ 前端节点面板双按钮。归属:kanban plugin + 前端,下一批。
- **㉕ 改记(2026-07-16 用户细化,取代㉔)**:**删除与 drop 仍分开**,但 drop 语义重定义——设计意图:节点挂的**北极星指标不达标**时 drop,做**跟踪**非删除。新 drop 语义:①**不删**节点与子树;②节点(及子树)的框渲染成**红色**;③仍记录 drop 历史+**理由**(:drops 保留,记 %{id, reason, at, by});④**drop 权限归节点的认领人**(非整树校验)。删除(remove/含子树)保持 collab 规则5 授权不变。开放点:要不要可撤销(un-drop)、红框子树里他人认领节点的显示细节。涉及:kanban behavior(drop_subtree 改非破坏性标记)+ 前端红框渲染。归属:kanban plugin+前端,下一批。
- **㉖ 记录(2026-07-16 手动测试)**:节点属性面板**没有显示/编辑节点名称的地方**——面板顶部只展示标题文本(不可编辑),改名藏在底部小按钮「改名」(walk window.prompt),没有就地编辑输入框;且画布上**节点框不能拖动调大小**,名字长了显示不全(截断成「产品…」)。修法:属性面板加名称字段(就地编辑,替代 prompt);画布节点框自适应文本宽度或可调大小/悬停显全名。归属:world 前端(KanbanCanvas/节点面板),下一批。
- **㉗ 设计规格(2026-07-16 用户定):节点属性面板布局重做**——
  ①「本图配置」块移除(同㉓);
  ②布局:前两排信息 + 「加子」「认领」两按钮保持;**其余一律一条信息一排**;
  ③产物区重做:「挂:」改「**添加**」+ **下拉框**(选项:链接/内容/画图/**附件**)+ 旁边「添加」(或+)按钮;
    - kanban plugin 不再负责绑 github → **去掉 SHA(挂代码文件)选项,统一收束到「链接」**;
    - **补回「附件」上传选项**(原来有,现在少了;平台 uploads 机制现成);
    - **每个已添加产物要有删除按钮**(detach 有动作无入口);
    - **「内容」编辑照「画图」样式**:弹大框,用一个最简 md 编辑器(类 excalidraw 的交互形态)。
  归属:world 前端(Kanban.tsx 节点面板),下一批实施。
- **㉘ 记录(2026-07-16 手动测试)**:取消认领(以及推断:任何看板节点操作)在**别的用户**界面不自动刷新——A 退领后 B 的画布还显示旧认领态,要手动刷新。与 ⑰(成员变动)㉒(建板)同根:**看板状态变更没有向同会话其他在线成员广播**(操作方自己有 push_tree 刷新,别人没有)。修法方向:kanban 变更后 broadcast 到 session topic(成员的 WorldLive 已订阅自己打开的会话,ensure_session_subscribed 通道现成)→ 收到后重拉 board_state。归属:world 实时面,与⑰㉒并一个修复项。
- **㉙ 记录(2026-07-16 用户重申,collab 模型规则9)**:分享应是**两个选项**——①**分享到会话**:把板以**气泡**直接发进当前 session 的 chat(消息气泡带板引用/链接,点击进入者按身份过滤权限:本会话成员=可编辑,其余=只读——「逻辑上都是一个链接,按点击者过滤」);②**复制分享链接**:现有的只读链接生成。现 UI 只有②。归属:world 前端(分享对话框)+ 气泡消息(session.send 带 render 引用),下一批。
- **㉚ 记录(2026-07-16 手动测试)**:分享对话框「复制链接」点击**没复制**——大概率 `navigator.clipboard` 只在安全上下文(https/localhost)可用,经 `http://<IP>` 访问时静默失败(对话框文案还写着「已自动复制到剪贴板」,双重误导)。修法:clipboard 失败时回退(选中文本/execCommand)+ 复制成败给出真实反馈;链接输入框本身可选中兜底。归属:world 前端(分享对话框),下一批。
- **㉛ 记录(2026-07-16 用户定):session-template 与 socialware 解绑 + 缺「安装 socialware」面**——建会话选的是 session-template,但 template 和 sw 不是绑定关系。应有独立的「安装 socialware」入口:给**已存在**的会话选装哪些 sw(可多个),然后可把当前会话的配置**保存成 session template**,后续可发布、被别人看到复用。现状:只有建会话向导里一次性选一个「应用」,没有装/卸/保存为模板的面。归属:world 会话管理面 + template/install 机制衔接。
- **㉜ 记录(2026-07-16 用户定,修正⑤的门控模型):kanban tab = plugin 级,所有会话都应有**——plugin 和 sw 分离:系统装了 kanban plugin,**所有会话都应显示 kanban tab**(tab 的存在表示系统有此 plugin);装不装 kanban sw 只决定有没有 assistant/团队增强。**推论:⑤ 的 render-cap 门控 tab 方向要改**——tab 不再按 sw 安装门控(始终可见),被门控的是板内容/钥匙(没钥匙=空列表/只读)。这也让「分享链接在任何会话点开才有意义」(用户点3)。归属:view 门控模型(KanbanRender/SessionView),与 Allen 的 view-cap 线对齐后改。
- **㉝ 记录(2026-07-16 用户定):分享链接粘进会话应自动渲染成气泡(飞书式)**——把分享链接粘贴到任何会话 chat:①自动 unfurl 成看板气泡(与 ㉙「分享到会话」同一气泡形态);②点击气泡:本会话 kanban list 没有这块板 → **把板加进本会话的看板列表**(挂载),之后可走「申请编辑」(规则8)。现状:粘贴的链接在气泡里甚至不可点击(纯文本)。归属:chat 消息渲染(链接 unfurl)+ 气泡点击挂载动作,与 ㉙ 合并实施。
- **㉞ 记录(2026-07-16 手动测试)**:看板底部「✓已保存」常驻显示,无意义且误导——kanban 没有保存概念(每个动作即时提交),这个标记实为 last_dispatch_status=="ok" 的常驻渲染;而页面又不实时更新(㉘),「已保存」读起来更像假话。修法:去掉常驻标记,改成 per-action 即时反馈(成功轻提示/失败 toast——失败提示已有);或等 ⑰㉒㉘ 推送落地后改成真实「同步状态」。归属:world 前端(Kanban.tsx),并入下一批。
- **⑯-修正(2026-07-16 用户二次澄清)**:**不是「必须同 workspace 分享」**——当前测试场景恰好同 ws;跨 ws 分享/申请编辑/添加若系统支撑则同样成立,**以系统状态为准**。系统实态(实证):①跨 ws URI 寻址+授权**已通**(e2e:owner ws 的板 → viewer ws 的 assistant,`access=read` 挂载成功,dispatch get_tree 过 CBAC——机制无 ws 屏障);②plugin 安装是**系统级**(plugin=OTP app,单 runtime 全 ws 共享代码,不存在「某 ws 没装 kanban plugin」;per-ws 的是数据:definition 发布(scope:public 跨 ws 可发现)/recipe(seeded 到 system ws)/caps);③现存不一致:chat 转发路 `forward_board` 有 #1435 的 `same_workspace` 硬守卫,而链接分享路(share controller)无 ws 检查——两路口径不一,**要不要统一、往哪边统一交 Allen**(用户倾向:系统支撑就放开)。
- **㉟ 记录(2026-07-17 手测r3)**:建会话「应用」下拉里内置 definition 直接以系统概念名「socialware」示人,用户误选(装成 builtin socialware 而非 kanban,session=socialware-install-socialware/*,无看板tab)。修法:builtin(chat/socialware/orchestrator)在普通用户选择器里改说明性名或隐藏。归属:world 向导(zyli 面)+ builtin definition 命名(Allen)。
- **㉛-设计意图(2026-07-17 用户澄清)**:template 与 sw **刻意不绑定**——一个 session 可关联**多个** socialware;session template 可从某个 sw 出发继续搭建 agent 等、**沉淀成新的 sw**,也可拉取多个 sw 组合。⟹ ㉛ 的「装 sw 面」要按多装/组合/存模板→发布成新 sw 的闭环设计(非单选绑定)。同步进 zyli #1443 的 ㉛ 节。
- **㉟-根因确认(2026-07-17)**:「关联了 sw 却没看板」双层根因——表层=误选 builtin「socialware」条目(㉟命名);深层=tab 出现与否取决于「装没装 kanban sw+render cap」(⑤门控模型),违背 ㉜「tab=plugin 级恒显」。**㉜(D3)+㉛(多 sw 绑定面)落地后此坑消失**:tab 恒在,sw 事后可在 ㉛ 面加/换;残余=⑩装了但角色静默跳过仍需提示(gaga/zyli)。
- **㊱ 记录(2026-07-17 手测r3)**:没有删除 session 的 UI(domain 有 teardown/retire 语义,界面无入口)。归属:world 会话管理面(zyli #1443 追加)。
